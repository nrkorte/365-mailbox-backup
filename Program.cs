using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using Aspose.Email;
using Aspose.Email.Clients;
using Aspose.Email.Clients.Graph;
using Aspose.Email.Mapi;
using Aspose.Email.Storage.Pst;
using Aspose.Email.Tools.Search;
using Microsoft.Identity.Client;
// Aspose.Email.Clients.Graph and Aspose.Email.Storage.Pst both define
// FolderInfo/FolderInfoCollection/MessageInfo - alias the Graph ones so the
// bare (unaliased) name always means the PST-side type used in PstChunkWriter.
using GraphFolderInfo = Aspose.Email.Clients.Graph.FolderInfo;
using GraphFolderInfoCollection = Aspose.Email.Clients.Graph.FolderInfoCollection;
using GraphMessageInfo = Aspose.Email.Clients.Graph.MessageInfo;

// ---------------------------------------------------------------------------
// M365 mailbox -> PST backup
//
// Auth:     OAuth2 client-credentials flow (MSAL), app-only (no signed-in
//           user).
// Target:   a specific mailbox by SMTP address, via the app's Mail.Read (or
//           Mail.ReadWrite) APPLICATION permission on Microsoft Graph,
//           admin-consented tenant-wide - NOT the credential/app's own
//           mailbox. Set via client.ResourceId below.
// Output:   one .pst file containing every mail folder in the mailbox,
//           recursively.
// Protocol: Microsoft Graph, via Aspose.Email.Clients.Graph.GraphClient.
// ---------------------------------------------------------------------------

LoadDotEnvFile(Path.Combine(Directory.GetCurrentDirectory(), ".env"));

string tenantId = RequireEnv("M365_TENANT_ID");
string clientId = RequireEnv("M365_CLIENT_ID");
string clientSecret = RequireEnv("M365_CLIENT_SECRET");

// Mailbox and date range change on every invocation, so they're command-line
// arguments rather than .env values - .env is reserved for the static
// app-registration credentials that stay the same across runs.
(string targetMailbox, DateTime? fromDate, DateTime? toDate, string? progressFilePath, string? manifestFilePath) = ParseArgs(args);

string pstPath = Environment.GetEnvironmentVariable("M365_PST_PATH")
    ?? Path.Combine(DefaultBackupDirectory(), DefaultPstFileName(targetMailbox, fromDate, toDate));

// Scoped 1:1 with pstPath (mailbox + optional date-range chunk), so an
// interrupted run leaves behind exactly the state a later resubmission of
// this same mailbox/range needs to resume - and nothing a sibling chunk job
// would ever look at. See the ResumeState class below for the full design.
using ResumeState resumeState = new ResumeState(pstPath);
if (resumeState.IsResuming)
{
    Console.WriteLine($"Resuming an interrupted backup - {resumeState.TotalAlreadyCopied} item(s) already copied last time will be skipped.");
}

// Split output into multiple .pst files (<name>.pst, <name>-part2.pst, ...)
// once a chunk's on-disk file size hits this many GB, instead of one
// unbounded file.
int chunkSizeLimitGb = ParseOptionalInt(Environment.GetEnvironmentVariable("M365_CHUNK_SIZE_GB")) ?? 15;
long chunkSizeLimitBytes = chunkSizeLimitGb * 1024L * 1024L * 1024L;

const string graphScope = "https://graph.microsoft.com/.default";

// Items per ListMessages page and per Graph mail-folder listing call - bounds
// how much a single failed page can lose (see ListMessagesPaged) to a small,
// fixed amount instead of an entire folder, however large.
const int ListPageSize = 200;

// Apply a license if one is present next to the project (e.g. a temporary
// license from Aspose) - otherwise this runs under evaluation-mode limits.
string licensePath = Path.Combine(Directory.GetCurrentDirectory(), "Aspose.Emailfor.NET.lic");
if (File.Exists(licensePath))
{
    new License().SetLicense(licensePath);
    Console.WriteLine("Aspose.Email license applied.");
}
else
{
    Console.WriteLine("No Aspose.Email license found - running in evaluation mode.");
}
Console.WriteLine();

Console.WriteLine($"Target mailbox : {targetMailbox}");
Console.WriteLine($"PST output     : {pstPath}");
Console.WriteLine();

// 1. Set up an app-only MSAL client-credentials app. We don't fetch a token
//    up front - instead we hand Aspose a token *provider* (below) so it can
//    pull a fresh token whenever it needs one, since a large mailbox can run
//    longer than a single access token (~60-90 min) lives.
Console.WriteLine("Configuring OAuth2 client credentials (MSAL)...");
IConfidentialClientApplication app = ConfidentialClientApplicationBuilder
    .Create(clientId)
    .WithClientSecret(clientSecret)
    .WithAuthority(new Uri($"https://login.microsoftonline.com/{tenantId}"))
    .Build();

// 2. Build the Graph client using the OAuth2 token provider instead of Basic
//    Auth. MsalTokenProvider (below) satisfies Aspose's ITokenProvider by
//    delegating to MSAL, which keeps its own token cache and silently
//    renews before expiry.
MsalTokenProvider tokenProvider = new MsalTokenProvider(app, new[] { graphScope });
IGraphClient client = GraphClient.GetClient(tokenProvider, tenantId);

// 3. Target a specific mailbox by SMTP address - points the client at
//    /users/{targetMailbox}/... for every call. Requires the app registration
//    to hold an admin-consented Mail.Read (or Mail.ReadWrite) APPLICATION
//    permission - see README for setup.
client.Resource = ResourceType.Users;
client.ResourceId = targetMailbox;

// 4. Aspose's Graph client has its own built-in retry policy that honors
//    Graph's real Retry-After header when present (RetryAfterThen-
//    ExponentialBackoffWithJitter), falling back to backoff-with-jitter
//    otherwise.
client.RetryPolicy = new GraphRetryPolicy
{
    Enabled = true,
    MaxRetryAttempts = 5,
    BaseDelay = TimeSpan.FromSeconds(2),
    MaxDelay = TimeSpan.FromSeconds(60),
    DelayStrategy = GraphRetryDelayStrategy.RetryAfterThenExponentialBackoffWithJitter
};

// 5. On top of Graph's own reactive retry-after-a-throttle handling above,
//    proactively pace every outgoing call to stay under the throttling
//    ceiling in the first place. Microsoft's documented per-mailbox
//    application throttling budget for mail access is on the order of
//    10,000 requests per 10 minutes (~16-17 req/s); the default here is
//    deliberately well under that to leave headroom for anything else
//    hitting this mailbox/tenant concurrently. Override via
//    M365_GRAPH_MAX_REQUESTS_PER_SECOND if a tenant's real budget supports
//    more (or needs to be more conservative than the default).
double graphMaxRequestsPerSecond = ParseOptionalDouble(Environment.GetEnvironmentVariable("M365_GRAPH_MAX_REQUESTS_PER_SECOND")) ?? 8.0;
GraphRateLimiter rateLimiter = new GraphRateLimiter(graphMaxRequestsPerSecond);
Console.WriteLine($"Graph rate limit: {graphMaxRequestsPerSecond.ToString("0.##", CultureInfo.InvariantCulture)} req/s proactive pacing, plus Graph's own adaptive retry policy on top");

// The first real network call of the whole run, made exactly once, before
// any output file exists, so a single transient throttling blip doesn't
// crash the job before it's done any work. Terminal if it still fails after
// retries: without this, there's nothing to walk or back up at all.
// client.ResourceId above already targets the mailbox directly, so this
// listing call doubles as the connectivity check.
GraphFolderInfoCollection rootFoldersForConnectivityCheck = RetryGraphCall(() => client.ListFolders(null), "top-level folder listing", 0, rateLimiter)
    ?? throw new InvalidOperationException("Could not list the mailbox's top-level folders after retrying - aborting.");
Console.WriteLine($"Resolved mailbox: {targetMailbox} ({rootFoldersForConnectivityCheck.Count} top-level folder(s))");
Console.WriteLine();

// Resuming needs a stable upper bound, or Graph's paging (no $orderby, no
// delta query - see ListMessagesPaged below) could see its result set grow
// between attempts as new mail arrives. Freeze it once, the first time a
// mailbox/range is ever resumed, and reuse it on every later attempt - a
// first-ever attempt is untouched (IsResuming is false here). This is a
// defensive measure on top of the real correctness mechanism (per-item ID
// checks in BackupFolderRecursively), not a replacement for it.
if (!toDate.HasValue && resumeState.IsResuming)
{
    toDate = resumeState.GetOrFreezeToCutoff(DateTime.UtcNow);
}

// 6. Build the date filter, if requested, once, up front.
MailQuery? dateFilter = null;
if (fromDate.HasValue || toDate.HasValue)
{
    // Calling Since()/Before() on the same builder's InternalDate field ANDs
    // both conditions together into one query - this is what lets --from/--to
    // carve out a non-overlapping year-over-year slice of a large mailbox,
    // e.g. --from 2023-01-01 --to 2024-01-01 for calendar year 2023.
    MailQueryBuilder dateFilterBuilder = new MailQueryBuilder();
    if (fromDate.HasValue)
    {
        dateFilterBuilder.InternalDate.Since(fromDate.Value);
    }
    if (toDate.HasValue)
    {
        dateFilterBuilder.InternalDate.Before(toDate.Value);
    }
    dateFilter = dateFilterBuilder.GetQuery();

    string rangeDescription = (fromDate.HasValue, toDate.HasValue) switch
    {
        (true, true) => $"from {fromDate:yyyy-MM-dd} up to (not including) {toDate:yyyy-MM-dd}",
        (true, false) => $"since {fromDate:yyyy-MM-dd}",
        (false, true) => $"before {toDate:yyyy-MM-dd}",
        _ => ""
    };
    Console.WriteLine($"Filtering to messages received {rangeDescription}.");
}

Console.WriteLine($"PST chunk size : {chunkSizeLimitGb} GB per file");
Console.WriteLine();

// Only relevant when running under the job queue (queue-worker.sh passes
// --progress-file so queue-status.sh has something to poll) - a no-op
// otherwise, so plain manual runs (backup-mailbox.sh, dotnet run without
// --progress-file) do the extra counting pass below for nothing and behave
// exactly as before.
ProgressWriter progress = new ProgressWriter(progressFilePath);
ManifestWriter manifest = new ManifestWriter(manifestFilePath);
if (progressFilePath is not null || manifestFilePath is not null)
{
    Console.WriteLine("Computing total item count for progress reporting...");
    int totalItems = 0;
    GraphFolderInfoCollection topLevelFoldersForCount = RetryGraphCall(() => client.ListFolders(null), "top-level folder listing", 0, rateLimiter)
        ?? throw new InvalidOperationException("Could not list the mailbox's top-level folders after retrying - aborting.");

    if (dateFilter is null)
    {
        // No date filter means nothing is being excluded, so each folder's
        // own ContentCount (already returned for free by ListFolders - no
        // extra network call) is exactly the count a full listing pass
        // would give us. Skips a redundant per-folder listing pass entirely.
        foreach (GraphFolderInfo folder in topLevelFoldersForCount)
        {
            totalItems += CountEligibleItemsFast(client, rateLimiter, folder);
        }
    }
    else
    {
        foreach (GraphFolderInfo folder in topLevelFoldersForCount)
        {
            totalItems += CountEligibleItems(client, rateLimiter, folder, dateFilter);
        }
    }

    progress.SetTotal(totalItems);
    manifest.SetExpectedTotal(totalItems);
    Console.WriteLine($"Total items to back up: {totalItems}");
    Console.WriteLine();
}

// 7. Recursively walk every mail folder in the mailbox (Inbox, Sent Items,
//    Deleted Items, custom folders, subfolders, ...), copying matching
//    messages into the PST as we go. Graph's /mailFolders navigation
//    property only ever returns mail folders - Calendar, Contacts, and Tasks
//    are separate Graph resources entirely outside this tree. Chunking to a
//    new .pst file once the current one hits chunkSizeLimitBytes on disk is
//    handled inside PstChunkWriter.
Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(pstPath))!);

Console.WriteLine("Enumerating folders and copying messages...");
using (PstChunkWriter writer = new PstChunkWriter(pstPath, chunkSizeLimitBytes, resumeState))
{
    GraphFolderInfoCollection topLevelFolders = RetryGraphCall(() => client.ListFolders(null), "top-level folder listing", 0, rateLimiter)
        ?? throw new InvalidOperationException("Could not list the mailbox's top-level folders after retrying - aborting.");
    foreach (GraphFolderInfo folder in topLevelFolders)
    {
        BackupFolderRecursively(client, rateLimiter, folder, new List<string>(), writer, dateFilter, 0, progress, manifest, resumeState);
    }

    Console.WriteLine();
    Console.WriteLine($"Done. Copied {writer.TotalItemsWritten} messages across {writer.ChunkCount} PST file(s) based on: {Path.GetFullPath(pstPath)}");
    manifest.MarkCompleted(writer.TotalItemsWritten);

    // Only reached after a full, uninterrupted walk of every top-level
    // folder above - a crash/kill never runs this line, which is what makes
    // "survive by default" work: there's no separate crash-detection branch
    // anywhere, the resume-state directory simply outlives an interrupted
    // process because nothing ever deletes it in that case.
    resumeState.Complete();
}

// Used only for date-filtered (chunked) jobs, where a folder's unfiltered
// ContentCount would overcount. Asks for one item via
// ListMessages(..., new PageInfo(1, 0), ...) and reads PageInfo.TotalCount
// off the result instead of doing a full listing pass.
static int CountEligibleItems(IGraphClient client, GraphRateLimiter rateLimiter, GraphFolderInfo folder, MailQuery dateFilter)
{
    int count = 0;
    GraphMessagePageInfo? page = RetryGraphCall(
        () => client.ListMessages(folder.ItemId, new PageInfo(1, 0), dateFilter),
        "a folder item count", 0, rateLimiter);
    if (page is not null)
    {
        // NextPage is only non-null when a second page actually exists, so a
        // folder with exactly 0-1 matching items has no NextPage to read
        // TotalCount from - fall back to what this one page itself returned
        // (0 or 1) instead of silently under-counting by 1.
        count += page.NextPage?.TotalCount ?? page.Items.Count;
    }

    // Gated on HasSubFolders (which ListFolders already told us for free).
    // Graph's REST childFolders listing returns an empty collection for a
    // folder with no children rather than throwing, so there's no
    // expected-exception case here to avoid retrying around.
    if (!folder.HasSubFolders)
    {
        return count;
    }

    GraphFolderInfoCollection? subFolders = RetryGraphCall(() => client.ListFolders(folder.ItemId, null), "subfolder listing", 0, rateLimiter);
    if (subFolders is null)
    {
        return count;
    }

    foreach (GraphFolderInfo subFolder in subFolders)
    {
        count += CountEligibleItems(client, rateLimiter, subFolder, dateFilter);
    }

    return count;
}

// Used only for unfiltered (full-mailbox) jobs. With no date filter, nothing
// is being excluded, so each folder's own ContentCount - already returned
// for free as part of ListFolders, no extra call needed - is exactly as
// accurate as actually listing every message would be.
static int CountEligibleItemsFast(IGraphClient client, GraphRateLimiter rateLimiter, GraphFolderInfo folder)
{
    int count = folder.ContentCount;

    if (!folder.HasSubFolders)
    {
        return count;
    }

    GraphFolderInfoCollection? subFolders = RetryGraphCall(() => client.ListFolders(folder.ItemId, null), "subfolder listing", 0, rateLimiter);
    if (subFolders is null)
    {
        return count;
    }

    foreach (GraphFolderInfo subFolder in subFolders)
    {
        count += CountEligibleItemsFast(client, rateLimiter, subFolder);
    }

    return count;
}

static void BackupFolderRecursively(IGraphClient client, GraphRateLimiter rateLimiter, GraphFolderInfo folder, List<string> parentPath, PstChunkWriter writer, MailQuery? dateFilter, int depth, ProgressWriter progress, ManifestWriter manifest, ResumeState resumeState)
{
    List<string> currentPath = new List<string>(parentPath) { folder.DisplayName };
    Console.WriteLine($"{new string(' ', depth * 2)}- {folder.DisplayName} ({folder.ContentCount} items)");

    int copiedCount = 0;
    IEnumerable<GraphMessageInfo> messages = ListMessagesPaged(client, rateLimiter, folder.ItemId, dateFilter, depth, currentPath, manifest, progress);

    // Aspose's Graph client fetches one message per call, so a
    // throttled/failed fetch only ever costs that one message.
    foreach (GraphMessageInfo message in messages)
    {
        string itemId = message.ItemId;

        // Resume dedup is keyed on the message's InternetMessageId (the
        // RFC 5322 Message-ID header, exposed here as MessageId) rather than
        // Graph's own ItemId, which is only guaranteed stable within a
        // session unless the client requests immutable ids - so the same
        // message can get a different ItemId on a later run. Falls back to
        // ItemId only for the rare message with no Message-ID at all.
        string resumeKey = string.IsNullOrEmpty(message.MessageId) ? itemId : message.MessageId;

        if (resumeState.IsAlreadyCopied(folder.ItemId, resumeKey))
        {
            // Already in the PST from an earlier, interrupted attempt at
            // this same mailbox/range - skip the network fetch entirely
            // (the expensive part), but still count it as accounted for so
            // a resumed run's progress% doesn't regress back toward 0.
            progress.RecordCopied(1, string.Join('/', currentPath));
            continue;
        }

        MapiMessage? fetched = RetryGraphCall(() => client.FetchMessage(itemId), "a message fetch", depth, rateLimiter);
        if (fetched is null)
        {
            manifest.RecordSkip(currentPath, SkipKind.MessageFetch, 1, "message fetch failed after retries");
            progress.RecordSkipped(1, string.Join('/', currentPath));
            continue;
        }

        if (writer.AddMessage(currentPath, fetched))
        {
            copiedCount++;
            resumeState.MarkCopied(folder.ItemId, resumeKey, writer.ChunkCount);
        }
        else
        {
            Console.WriteLine($"{new string(' ', depth * 2)}  [SKIPPED 1 message - MAPI class incompatible with this folder]");
            manifest.RecordSkip(currentPath, SkipKind.MapiIncompatible, 1, "MAPI class incompatible with this folder");
        }

        // Counts fetched (not written) messages - MapiIncompatible rejections
        // are already accounted for here, so they don't get their own
        // progress.RecordSkipped call too (that would double-count them).
        progress.RecordCopied(1, string.Join('/', currentPath));
    }

    if (copiedCount > 0)
    {
        Console.WriteLine($"{new string(' ', depth * 2)}  -> copied {copiedCount} message(s)");
    }

    if (folder.HasSubFolders)
    {
        GraphFolderInfoCollection? subFolders = RetryGraphCall(() => client.ListFolders(folder.ItemId, null), "subfolder listing", depth, rateLimiter);
        if (subFolders is not null)
        {
            foreach (GraphFolderInfo subFolder in subFolders)
            {
                BackupFolderRecursively(client, rateLimiter, subFolder, currentPath, writer, dateFilter, depth + 1, progress, manifest, resumeState);
            }
        }
    }
}

// Once a folder has failed this many CONSECUTIVE pages (each already having
// exhausted RetryGraphCall's own attempts, which themselves sit on top of
// Aspose's internal Graph retry policy), give up on the rest of that folder
// rather than looping forever against a sustained outage - subfolders are
// still walked independently either way.
const int MaxConsecutiveListingFailures = 5;

// Walks a folder's messages page by page instead of one unpaged listing call
// for the whole folder - bounds a failure to at most ListPageSize items lost
// instead of an entire folder, however large.
//
// IMPORTANT: PageInfo's "offset" here is a PAGE NUMBER, NOT an absolute item
// position, despite Aspose's docs reading as "offset in view of a page" -
// confirmed empirically: a small-page-size request at offset=1 returned
// items 5-9 of a 5-per-page view (page NUMBER 1), not item offset 5.
// Advancing pageIndex by 1 each iteration (not by ListPageSize) is therefore
// correct. Do not "fix" this to pageIndex * ListPageSize - that silently
// truncates every folder over one page to its first ListPageSize items, with
// no error logged, because the out-of-range request looks like a legitimate
// "no more items" response.
static IEnumerable<GraphMessageInfo> ListMessagesPaged(
    IGraphClient client, GraphRateLimiter rateLimiter, string folderId, MailQuery? dateFilter, int depth,
    IReadOnlyList<string> currentPath, ManifestWriter manifest, ProgressWriter progress)
{
    int pageIndex = 0;
    int consecutiveFailures = 0;

    while (true)
    {
        PageInfo requestPage = new PageInfo(ListPageSize, pageIndex);
        GraphMessagePageInfo? page = RetryGraphCall(
            () => client.ListMessages(folderId, requestPage, dateFilter),
            $"a folder listing page (page {pageIndex})",
            depth, rateLimiter);

        if (page is null)
        {
            consecutiveFailures++;
            manifest.RecordSkip(currentPath, SkipKind.ListingPage, ListPageSize, $"page {pageIndex} failed after retries");
            progress.RecordSkipped(ListPageSize, string.Join('/', currentPath));

            if (consecutiveFailures >= MaxConsecutiveListingFailures)
            {
                Console.WriteLine($"{new string(' ', depth * 2)}  [giving up on further pages after {consecutiveFailures} consecutive failures at page {pageIndex}]");
                yield break;
            }

            pageIndex++;
            continue;
        }

        consecutiveFailures = 0;
        foreach (GraphMessageInfo message in page.Items)
        {
            yield return message;
        }

        // LastPage is the primary signal; a page shorter than requested is
        // kept as a secondary/redundant check - either one stopping is safe,
        // since a truncated page unambiguously means nothing further exists.
        if (page.LastPage || page.Items.Count < ListPageSize)
        {
            yield break;
        }

        pageIndex++;
    }
}

// Aspose's GraphClient already retries transient Graph failures internally
// (see the RetryPolicy configured on `client` above). This wrapper is a
// last-resort safety net for whatever still gets through that budget (a
// throttling window longer than the policy's own retries cover, or a
// non-throttling transient error), and every attempt - including the first -
// is paced through rateLimiter so this run doesn't hammer the mailbox back
// up against the same throttling ceiling it's trying to stay under.
static T? RetryGraphCall<T>(Func<T> call, string description, int depth, GraphRateLimiter rateLimiter) where T : class
{
    const int OuterAttempts = 2;
    TimeSpan outerDelay = TimeSpan.FromSeconds(30);

    for (int attempt = 1; attempt <= OuterAttempts; attempt++)
    {
        rateLimiter.WaitForSlot();

        try
        {
            return call();
        }
        catch (Exception ex) when (attempt < OuterAttempts)
        {
            string detail = ex is GraphThrottlingException throttling && throttling.RetryAfter.HasValue
                ? $"{ex.Message} (server's Retry-After: {throttling.RetryAfter.Value.TotalSeconds:F0}s - already honored by Graph's own retry policy before this)"
                : ex.Message;
            Console.WriteLine($"{new string(' ', depth * 2)}  [retrying {description} after Graph's own retry budget was exhausted: {detail}]");
            Thread.Sleep(outerDelay);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"{new string(' ', depth * 2)}  [SKIPPED {description} - Graph's retry policy plus {OuterAttempts} outer attempts all failed: {ex.Message}]");
        }
    }

    return null;
}

// Matches the default backup-mailbox.ps1/.sh use when M365_PST_PATH isn't set.
// The Linux default assumes a separate /data volume sized for large mailbox
// exports - override with M365_PST_PATH if that's not where backups should go.
static string DefaultBackupDirectory()
{
    return OperatingSystem.IsWindows()
        ? @"C:\Backups"
        : "/data/backups";
}

// Command line usage: dotnet run -- <mailbox> [--from yyyy-MM-dd] [--to yyyy-MM-dd] [--progress-file <path>] [--manifest-file <path>]
// Parses the target mailbox, optional date range, and optional progress-file/
// manifest-file paths every run needs. Kept out of .env on purpose: unlike
// the tenant/client credentials, these change on every invocation.
static (string mailbox, DateTime? from, DateTime? to, string? progressFile, string? manifestFile) ParseArgs(string[] args)
{
    string? mailbox = null;
    DateTime? from = null;
    DateTime? to = null;
    string? progressFile = null;
    string? manifestFile = null;

    for (int i = 0; i < args.Length; i++)
    {
        switch (args[i])
        {
            case "--from":
                from = ParseDateArg("--from", RequireNextArg(args, ref i, "--from"));
                break;
            case "--to":
                to = ParseDateArg("--to", RequireNextArg(args, ref i, "--to"));
                break;
            case "--progress-file":
                progressFile = RequireNextArg(args, ref i, "--progress-file");
                break;
            case "--manifest-file":
                manifestFile = RequireNextArg(args, ref i, "--manifest-file");
                break;
            default:
                if (mailbox is not null)
                {
                    throw new InvalidOperationException(
                        $"Unexpected argument '{args[i]}'. Usage: dotnet run -- <mailbox> [--from yyyy-MM-dd] [--to yyyy-MM-dd] [--progress-file <path>] [--manifest-file <path>]");
                }
                mailbox = args[i];
                break;
        }
    }

    if (string.IsNullOrWhiteSpace(mailbox))
    {
        throw new InvalidOperationException(
            "Missing mailbox argument. Usage: dotnet run -- <mailbox> [--from yyyy-MM-dd] [--to yyyy-MM-dd] [--progress-file <path>] [--manifest-file <path>]");
    }

    if (from.HasValue && to.HasValue && from.Value >= to.Value)
    {
        throw new InvalidOperationException(
            $"--from ({from:yyyy-MM-dd}) must be earlier than --to ({to:yyyy-MM-dd}).");
    }

    return (mailbox, from, to, progressFile, manifestFile);
}

static string RequireNextArg(string[] args, ref int i, string flag)
{
    if (i + 1 >= args.Length)
    {
        throw new InvalidOperationException($"{flag} requires a value (yyyy-MM-dd).");
    }
    return args[++i];
}

static DateTime ParseDateArg(string flag, string value)
{
    if (!DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTime parsed))
    {
        throw new InvalidOperationException($"'{value}' for {flag} isn't a valid date - use yyyy-MM-dd (e.g. 2024-01-01).");
    }
    return DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
}

// Keeps separate chunk runs (e.g. --from 2023-01-01 --to 2024-01-01 followed by
// --from 2024-01-01 --to 2025-01-01) from overwriting each other's .pst when
// M365_PST_PATH isn't set explicitly, e.g. "someone@example.com[JAN2023-DEC2023].pst".
static string DefaultPstFileName(string mailbox, DateTime? from, DateTime? to)
{
    if (!from.HasValue && !to.HasValue)
    {
        return $"{mailbox}.pst";
    }

    // --to is exclusive, so its label reflects the last day actually included
    // (one day before --to), not --to itself - --to 2024-01-01 reads as DEC2023.
    string fromLabel = from.HasValue ? MonthYearLabel(from.Value) : "START";
    string toLabel = to.HasValue ? MonthYearLabel(to.Value.AddDays(-1)) : "PRESENT";
    return $"{mailbox}[{fromLabel}-{toLabel}].pst";
}

static string MonthYearLabel(DateTime date) =>
    date.ToString("MMM", CultureInfo.InvariantCulture).ToUpperInvariant() + date.ToString("yyyy", CultureInfo.InvariantCulture);

// Minimal .env loader: KEY=VALUE per line, '#' comments, blank lines ignored.
// Real environment variables (e.g. set by CI) always win over the file, so a
// deployment can override individual values without editing .env.
static void LoadDotEnvFile(string path)
{
    if (!File.Exists(path))
    {
        return;
    }

    foreach (string rawLine in File.ReadAllLines(path))
    {
        string line = rawLine.Trim();
        if (line.Length == 0 || line.StartsWith('#'))
        {
            continue;
        }

        int separatorIndex = line.IndexOf('=');
        if (separatorIndex <= 0)
        {
            continue;
        }

        string key = line[..separatorIndex].Trim();
        string value = line[(separatorIndex + 1)..].Trim().Trim('"');

        if (Environment.GetEnvironmentVariable(key) is null)
        {
            Environment.SetEnvironmentVariable(key, value);
        }
    }
}

static string RequireEnv(string name)
{
    string? value = Environment.GetEnvironmentVariable(name);
    if (string.IsNullOrWhiteSpace(value))
    {
        throw new InvalidOperationException(
            $"Required environment variable '{name}' is not set. See README for setup instructions.");
    }
    return value;
}

static int? ParseOptionalInt(string? value)
{
    return int.TryParse(value, out int parsed) ? parsed : null;
}

static double? ParseOptionalDouble(string? value)
{
    return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsed) ? parsed : null;
}

// Paces every outgoing Graph call to stay under Microsoft's per-mailbox
// application throttling budget. A simple fixed-interval gate rather than a
// token bucket: this program makes calls sequentially, one at a time, so
// there's no burst behavior to model - only "don't start the next call
// sooner than 1/rate seconds after the last one started."
class GraphRateLimiter
{
    private readonly object _lock = new();
    private readonly TimeSpan _minInterval;
    private DateTime _nextAllowedAt = DateTime.MinValue;

    public GraphRateLimiter(double maxRequestsPerSecond)
    {
        _minInterval = TimeSpan.FromSeconds(1.0 / maxRequestsPerSecond);
    }

    public void WaitForSlot()
    {
        TimeSpan waitTime;
        lock (_lock)
        {
            DateTime now = DateTime.UtcNow;
            DateTime start = now > _nextAllowedAt ? now : _nextAllowedAt;
            waitTime = start - now;
            _nextAllowedAt = start + _minInterval;
        }

        if (waitTime > TimeSpan.Zero)
        {
            Thread.Sleep(waitTime);
        }
    }
}

// Writes messages into a PST, automatically rolling over to a new file
// (<name>.pst, <name>-part2.pst, <name>-part3.pst, ...) once the current
// chunk's on-disk file size reaches chunkSizeLimitBytes. Checked via
// FileInfo.Length after every write rather than tracked in memory, since
// Aspose's PersonalStorage writes each AddMapiMessageItem straight through
// to the underlying FileStream with no buffering to account for. Folders
// are recreated lazily in whichever chunk is currently open - a folder path
// used across chunks gets its own fresh FolderInfo per chunk, since PST
// folder handles don't survive closing the file they belong to.
class PstChunkWriter : IDisposable
{
    private readonly string _basePath;
    private readonly long _chunkSizeLimitBytes;
    private readonly Dictionary<string, Aspose.Email.Storage.Pst.FolderInfo> _folderCache = new();
    private PersonalStorage? _current;
    private FileInfo? _currentFileInfo;

    public int TotalItemsWritten { get; private set; }
    public int ChunkCount { get; private set; }

    public PstChunkWriter(string basePath, long chunkSizeLimitBytes, ResumeState resumeState)
    {
        _basePath = basePath;
        _chunkSizeLimitBytes = chunkSizeLimitBytes;
        TotalItemsWritten = resumeState.TotalAlreadyCopied;

        if (resumeState.IsResuming && TryOpenLatestExistingChunk(resumeState))
        {
            return;
        }

        StartNewChunk();
    }

    // Finds the highest-numbered chunk file already on disk from an
    // interrupted prior attempt and reopens it for continued writing.
    // Returns false (falls through to a fresh StartNewChunk()) if no chunk
    // was ever created last time.
    private bool TryOpenLatestExistingChunk(ResumeState resumeState)
    {
        int highest = 0;
        while (File.Exists(ChunkPath(_basePath, highest + 1)))
        {
            highest++;
        }

        if (highest == 0)
        {
            return false;
        }

        string path = ChunkPath(_basePath, highest);
        try
        {
            _current = PersonalStorage.FromFile(path, true);
        }
        catch (Exception ex)
        {
            // A kill mid-write can leave the one chunk that was open at kill
            // time structurally unreadable. There's no partial recovery for
            // a corrupted compound file: drop just this one chunk and its
            // resume records (every earlier, already-closed chunk is
            // untouched) and start it over fresh.
            Console.WriteLine($"Chunk {highest} ({path}) could not be reopened ({ex.GetType().Name}: {ex.Message}) - discarding it and re-copying its contents.");
            resumeState.ForgetChunk(highest);
            File.Delete(path);
            ChunkCount = highest - 1;
            StartNewChunk();
            return true;
        }

        ChunkCount = highest;
        _currentFileInfo = new FileInfo(path);
        Console.WriteLine($"Resuming: reopened existing PST chunk {ChunkCount}: {path}");
        return true;
    }

    // Returns false if this specific message was skipped (see catch below) -
    // the caller logs that and moves on rather than treating it as fatal.
    public bool AddMessage(IReadOnlyList<string> folderPath, MapiMessage message)
    {
        try
        {
            ResolveFolder(folderPath).AddMapiMessageItem(message);
        }
        catch (Exception ex) when (ex is InvalidOperationException or NotSupportedException)
        {
            // Aspose's PST writer rejects some legitimate mailbox content it
            // can't represent - e.g. a bounce/NDR message whose MAPI class
            // doesn't match its folder's expected container class
            // (InvalidOperationException), or a class with no PST mapping at
            // all (NotSupportedException). Neither is transient, so skip
            // just this one message rather than losing the whole run.
            return false;
        }

        TotalItemsWritten++;

        // Checked after the write completes, not before - so a chunk always
        // gets at least one message even if a single oversized item alone
        // would exceed the limit, and the file that actually crossed the
        // threshold is the one that gets closed, rather than starting an
        // empty chunk pre-emptively.
        _currentFileInfo!.Refresh();
        if (_currentFileInfo.Length >= _chunkSizeLimitBytes)
        {
            StartNewChunk();
        }

        return true;
    }

    private Aspose.Email.Storage.Pst.FolderInfo ResolveFolder(IReadOnlyList<string> path)
    {
        Aspose.Email.Storage.Pst.FolderInfo parent = _current!.RootFolder;
        List<string> builtPath = new();

        foreach (string segment in path)
        {
            builtPath.Add(segment);
            string key = string.Join(' ', builtPath);

            if (!_folderCache.TryGetValue(key, out Aspose.Email.Storage.Pst.FolderInfo? folder))
            {
                // PersonalStorage.Create() pre-populates a fresh PST with the
                // standard folder set (Inbox, Deleted Items, Sent Items, ...),
                // so a name collision here is expected, not an error - reuse
                // the existing folder instead of trying to create a duplicate.
                folder = parent.GetSubFolder(segment, ignoreCase: true) ?? parent.AddSubFolder(segment);
                _folderCache[key] = folder;
            }

            parent = folder;
        }

        return parent;
    }

    private void StartNewChunk()
    {
        _current?.Dispose();
        ChunkCount++;

        string path = ChunkPath(_basePath, ChunkCount);
        if (File.Exists(path))
        {
            File.Delete(path);
        }

        _current = PersonalStorage.Create(path, FileFormatVersion.Unicode);
        _currentFileInfo = new FileInfo(path);
        _folderCache.Clear();

        Console.WriteLine($"Opened PST chunk {ChunkCount}: {path}");
    }

    private static string ChunkPath(string basePath, int chunkIndex)
    {
        if (chunkIndex == 1)
        {
            return basePath;
        }

        string dir = Path.GetDirectoryName(basePath) ?? "";
        string nameWithoutExt = Path.GetFileNameWithoutExtension(basePath);
        string ext = Path.GetExtension(basePath);
        return Path.Combine(dir, $"{nameWithoutExt}-part{chunkIndex}{ext}");
    }

    public void Dispose()
    {
        _current?.Dispose();
    }
}

// Reports backup progress to a JSON file for the job queue's status polling
// (queue-status.sh). A no-op when constructed with a null path, so plain
// manual runs (backup-mailbox.sh, dotnet run without --progress-file) never
// need a null check at the call sites.
class ProgressWriter
{
    private readonly string? _path;
    private int _totalItems;
    private int _copiedItems;
    private int _skippedItems;

    public ProgressWriter(string? path)
    {
        _path = path;
    }

    public void SetTotal(int totalItems)
    {
        _totalItems = totalItems;
        Write("");
    }

    public void RecordCopied(int count, string currentFolder)
    {
        _copiedItems += count;
        Write(currentFolder);
    }

    // Items that never made it into the PST at all (a listing page or
    // message fetch that exhausted retries) - tracked separately from
    // copiedItems so that field keeps meaning "what's actually in the PST."
    // Still advances percent below, alongside copiedItems, so a run with
    // real skips doesn't permanently under-report and look stuck.
    public void RecordSkipped(int count, string currentFolder)
    {
        _skippedItems += count;
        Write(currentFolder);
    }

    private void Write(string currentFolder)
    {
        if (_path is null)
        {
            return;
        }

        int accountedFor = Math.Min(_copiedItems + _skippedItems, _totalItems);
        int percent = _totalItems > 0 ? (int)Math.Round(accountedFor * 100.0 / _totalItems) : 0;
        var payload = new
        {
            total_items = _totalItems,
            copied_items = _copiedItems,
            skipped_items = _skippedItems,
            percent,
            current_folder = currentFolder,
            updated_at = DateTime.UtcNow.ToString("o")
        };

        // Write-then-rename (same directory) is an atomic Linux rename syscall,
        // so a concurrent reader (queue-status.sh) never sees a half-written file.
        string tempPath = _path + ".tmp";
        File.WriteAllText(tempPath, JsonSerializer.Serialize(payload));
        File.Move(tempPath, _path, overwrite: true);
    }
}

enum SkipKind
{
    ListingPage,

    // Aspose's Graph client fetches one message per call (no batch API), so
    // a fetch skip always represents exactly one item.
    MessageFetch,
    MapiIncompatible
}

// Tracks what a backup run skipped (never made it into the PST) so a job
// that drops data doesn't look identical to one that didn't. A no-op when
// constructed with a null path, matching ProgressWriter's pattern.
//
// total_skipped updates live on every RecordSkip call rather than only in a
// final summary - so if the process crashes partway through, the manifest
// still has a trustworthy total_skipped/total_expected even though
// MarkCompleted/total_copied never gets called. queue-worker.sh reads this
// file once the process exits, folds it into the job record, and deletes it -
// the manifest itself never outlives the job that created it.
class ManifestWriter
{
    private readonly string? _path;
    private readonly List<object> _skips = new();
    private int _totalExpected;
    private int _totalSkipped;
    private bool _completed;
    private int _totalCopied;

    public ManifestWriter(string? path)
    {
        _path = path;
        if (_path is not null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
        }
    }

    public void SetExpectedTotal(int totalItems)
    {
        _totalExpected = totalItems;
        Write();
    }

    public void RecordSkip(IReadOnlyList<string> folderPath, SkipKind kind, int itemCount, string reason)
    {
        _totalSkipped += itemCount;
        _skips.Add(new
        {
            folder = string.Join('/', folderPath),
            kind = kind.ToString(),
            item_count = itemCount,
            reason,
            at = DateTime.UtcNow.ToString("o")
        });
        Write();
    }

    public void MarkCompleted(int totalCopied)
    {
        _completed = true;
        _totalCopied = totalCopied;
        Write();
    }

    private void Write()
    {
        if (_path is null)
        {
            return;
        }

        var payload = new
        {
            total_expected = _totalExpected,
            total_copied = _completed ? _totalCopied : (int?)null,
            total_skipped = _totalSkipped,
            completed = _completed,
            skips = _skips,
            updated_at = DateTime.UtcNow.ToString("o")
        };

        string tempPath = _path + ".tmp";
        File.WriteAllText(tempPath, JsonSerializer.Serialize(payload));
        File.Move(tempPath, _path, overwrite: true);
    }
}

// Durable, crash-safe checkpoint of which Graph message IDs have already
// been copied into a mailbox's PST, so an interrupted run (crash, kill,
// unclean restart) can resume near where it left off instead of recopying
// everything from item 1. Not wired to any signal handler - every write
// below is flushed immediately instead, so correctness comes from "the file
// already has whatever was durably written before the process died."
//
// Scoped one-to-one with a specific pstPath (mailbox + optional date-range
// chunk), so sibling year-chunk jobs for the same mailbox never share state.
//
// IDs are tracked per (Graph folder id, PST chunk number) rather than just
// per folder: if the chunk that was open at kill time turns out corrupted on
// reopen (see PstChunkWriter.TryOpenLatestExistingChunk), only that chunk's
// records need discarding (ForgetChunk) - earlier, already-closed chunks are
// unaffected. Folder ids are hashed for use as filename/dictionary keys since
// Graph's opaque folder id format isn't documented as filename-safe.
class ResumeState : IDisposable
{
    private readonly string _dir;
    private readonly string _foldersDir;
    private readonly string _stateFile;
    private readonly Dictionary<string, HashSet<string>> _copiedByFolderKey = new();
    private readonly Dictionary<string, StreamWriter> _openWriters = new();
    private DateTime? _toCutoff;

    public bool IsResuming { get; }
    public int TotalAlreadyCopied { get; }

    public ResumeState(string pstPath)
    {
        string fullPstPath = Path.GetFullPath(pstPath);
        _dir = Path.Combine(
            Path.GetDirectoryName(fullPstPath)!,
            ".resume-" + Path.GetFileNameWithoutExtension(fullPstPath));
        _foldersDir = Path.Combine(_dir, "folders");
        _stateFile = Path.Combine(_dir, "state.json");

        IsResuming = Directory.Exists(_dir);
        Directory.CreateDirectory(_foldersDir);

        if (!IsResuming)
        {
            TotalAlreadyCopied = 0;
            return;
        }

        if (File.Exists(_stateFile))
        {
            JsonElement root = JsonSerializer.Deserialize<JsonElement>(File.ReadAllText(_stateFile));
            if (root.TryGetProperty("to_cutoff", out JsonElement cutoffEl) && cutoffEl.ValueKind == JsonValueKind.String)
            {
                _toCutoff = DateTime.Parse(cutoffEl.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
            }
        }

        int total = 0;
        foreach (string idFile in Directory.GetFiles(_foldersDir, "*__chunk*.ids"))
        {
            string folderKey = FolderKeyFromIdFileName(Path.GetFileName(idFile));
            HashSet<string> set = GetOrAddFolderSet(folderKey);
            foreach (string line in File.ReadLines(idFile))
            {
                if (line.Length > 0 && set.Add(line))
                {
                    total++;
                }
            }
        }
        TotalAlreadyCopied = total;
    }

    public bool IsAlreadyCopied(string folderId, string itemId) =>
        _copiedByFolderKey.TryGetValue(FolderKey(folderId), out HashSet<string>? set) && set.Contains(itemId);

    public void MarkCopied(string folderId, string itemId, int chunkNumber)
    {
        string folderKey = FolderKey(folderId);
        GetOrAddFolderSet(folderKey).Add(itemId);

        StreamWriter writer = GetOrOpenWriter(folderKey, chunkNumber);
        writer.WriteLine(itemId);
        writer.Flush();
    }

    public DateTime GetOrFreezeToCutoff(DateTime now)
    {
        if (_toCutoff.HasValue)
        {
            return _toCutoff.Value;
        }

        _toCutoff = now;
        string tempPath = _stateFile + ".tmp";
        File.WriteAllText(tempPath, JsonSerializer.Serialize(new { to_cutoff = now.ToString("o") }));
        File.Move(tempPath, _stateFile, overwrite: true);
        return now;
    }

    // Discards every recorded id for one chunk (folder-by-folder) - used
    // when that chunk's .pst file turns out unreadable on reopen, so its
    // contents get re-fetched instead of being permanently treated as
    // "already copied" while actually missing from disk.
    public void ForgetChunk(int chunkNumber)
    {
        foreach (string idFile in Directory.GetFiles(_foldersDir, $"*__chunk{chunkNumber}.ids"))
        {
            string folderKey = FolderKeyFromIdFileName(Path.GetFileName(idFile));
            if (_copiedByFolderKey.TryGetValue(folderKey, out HashSet<string>? set))
            {
                foreach (string line in File.ReadLines(idFile))
                {
                    if (line.Length > 0)
                    {
                        set.Remove(line);
                    }
                }
            }

            File.Delete(idFile);
        }
    }

    // Only reached after a full, uninterrupted folder walk finishes - a
    // crash/kill never runs this, so the resume-state directory simply
    // outlives an interrupted process because nothing else ever deletes it.
    public void Complete()
    {
        Dispose();
        Directory.Delete(_dir, recursive: true);
    }

    // Normal (non-signal) process exit/exception unwind - just closes file
    // handles cleanly. Does NOT delete anything: every write is already
    // flushed immediately (see MarkCopied), so an interrupted run is already
    // safely resumable the moment MarkCopied returns.
    public void Dispose()
    {
        foreach (StreamWriter writer in _openWriters.Values)
        {
            writer.Dispose();
        }
        _openWriters.Clear();
    }

    private HashSet<string> GetOrAddFolderSet(string folderKey)
    {
        if (!_copiedByFolderKey.TryGetValue(folderKey, out HashSet<string>? set))
        {
            set = new HashSet<string>();
            _copiedByFolderKey[folderKey] = set;
        }
        return set;
    }

    private StreamWriter GetOrOpenWriter(string folderKey, int chunkNumber)
    {
        string key = $"{folderKey}__chunk{chunkNumber}";
        if (!_openWriters.TryGetValue(key, out StreamWriter? writer))
        {
            string path = Path.Combine(_foldersDir, $"{key}.ids");
            writer = new StreamWriter(new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read));
            _openWriters[key] = writer;
        }
        return writer;
    }

    private static string FolderKey(string folderId) =>
        Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(folderId)));

    // "<folderKey>__chunk<N>.ids" - folderKey is our own hex-encoded hash
    // (see FolderKey), never the raw Graph id, so it can never itself
    // contain "_" - splitting on the first "__chunk" is always unambiguous.
    private static string FolderKeyFromIdFileName(string fileName) =>
        fileName[..fileName.IndexOf("__chunk", StringComparison.Ordinal)];
}

// Bridges Aspose's synchronous ITokenProvider to MSAL. MSAL's confidential
// client app keeps its own in-memory app-token cache: a plain
// AcquireTokenForClient call returns the cached token silently until shortly
// before it expires, then fetches a new one automatically. WithForceRefresh
// is only used when Aspose explicitly asks us to ignore the existing token
// (e.g. after a request came back unauthorized), so this doesn't hammer
// Entra ID on every single call.
class MsalTokenProvider : ITokenProvider
{
    private readonly IConfidentialClientApplication _app;
    private readonly string[] _scopes;

    public MsalTokenProvider(IConfidentialClientApplication app, string[] scopes)
    {
        _app = app;
        _scopes = scopes;
    }

    public OAuthToken GetAccessToken() => GetAccessToken(false);

    public OAuthToken GetAccessToken(bool ignoreExistingToken)
    {
        AuthenticationResult result = _app.AcquireTokenForClient(_scopes)
            .WithForceRefresh(ignoreExistingToken)
            .ExecuteAsync()
            .GetAwaiter()
            .GetResult();

        return new OAuthToken(result.AccessToken, result.ExpiresOn.UtcDateTime);
    }

    public void Dispose()
    {
        // Nothing to release - the IConfidentialClientApplication is owned by
        // the caller, not this provider.
    }
}
