//
//  AppListViewController.m
//  App Downgrade — app picker, version picker and purchase trigger.
//
//  Flow:
//    local app  -> iTunes lookup (bundleId -> trackId) -> history API
//    search hit -> PreFetchedTrackID from the search result -> history API
//    version    -> app_downgrade_trigger_in_springboard(appInfo, AppExtVrsId)
//
//  Everything that touches the App Store daemon lives in the payload; this
//  controller only resolves IDs and drives UI.
//

#import "AppListViewController.h"
#import "AppDowngrade.h"
#import "../installer/InstallProgressViewController.h"

#import <UIKit/UIKit.h>

static NSString * const kAppCellIdentifier = @"AppCell";

static NSString * const kLookupByBundleIDURL = @"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software&country=%@";
static NSString * const kLookupByIDURL       = @"https://itunes.apple.com/lookup?id=%@&country=%@";
static NSString * const kSearchURL           = @"https://itunes.apple.com/search?term=%@&entity=software&limit=25&country=%@";
static NSString * const kHistoryURL          = @"https://apis.bilin.eu.org/history/%lld";
static NSString * const kDowngradeErrorDomain = @"Downgrade";

// Populated once per process; the container scan is not cheap and the list only
// changes after an install/uninstall, which forceRefreshApps covers.
static NSArray<NSDictionary *> *gInstalledApps = nil;

#pragma mark - Helpers

// Storefront list used when resolving a bundleId. The first entry is the
// preferred region; the rest are tried in order until iTunes returns a hit.
static NSArray<NSString *> *applist_supported_country_codes(void)
{
    static NSArray<NSString *> *codes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        codes = @[@"cn", @"us", @"ae", @"ag", @"ai", @"al", @"am", @"ao", @"ar", @"at",
                  @"au", @"az", @"bb", @"be", @"bf", @"bg", @"bh", @"bj", @"bm", @"bn",
                  @"bo", @"br", @"bs", @"bt", @"bw", @"by", @"bz", @"ca", @"cg", @"ch",
                  @"ci", @"cl", @"cm", @"co", @"cr", @"cv", @"cy", @"cz", @"de", @"dk",
                  @"dm", @"do", @"dz", @"ec", @"ee", @"eg", @"es", @"fi", @"fj", @"fm",
                  @"fr", @"gb", @"gd", @"gh", @"gm", @"gr", @"gt", @"gw", @"gy", @"hk",
                  @"hn", @"hr", @"hu", @"id", @"ie", @"il", @"in", @"is", @"it", @"jm",
                  @"jo", @"jp", @"ke", @"kg", @"kh", @"kn", @"kr", @"kw", @"ky", @"kz",
                  @"la", @"lb", @"lc", @"lk", @"lr", @"lt", @"lu", @"lv", @"md", @"mg",
                  @"mk", @"ml", @"mn", @"mo", @"mr", @"ms", @"mt", @"mu", @"mw", @"mx",
                  @"my", @"na", @"ne", @"ng", @"ni", @"nl", @"no", @"np", @"nz", @"om",
                  @"pa", @"pe", @"pg", @"ph", @"pk", @"pl", @"pt", @"pw", @"py", @"qa",
                  @"ro", @"ru", @"rw", @"sa", @"sb", @"sc", @"se", @"sg", @"si", @"sk",
                  @"sl", @"sn", @"sr", @"st", @"sv", @"sz", @"tc", @"td", @"th", @"tj",
                  @"tm", @"tn", @"tr", @"tt", @"tw", @"tz", @"ua", @"ug", @"uy", @"uz",
                  @"vc", @"ve", @"vg", @"vn", @"ye", @"za", @"zm", @"zw"];
    });
    return codes;
}

static NSString *applist_device_country_code(void)
{
    NSString *code = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return code.length ? code : @"us";
}

static NSArray<NSDictionary *> *applist_scan_installed_apps(void)
{
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/containers/Bundle/Application";

    for (NSString *bucket in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *bucketPath = [root stringByAppendingPathComponent:bucket];
        for (NSString *entry in [fm contentsOfDirectoryAtPath:bucketPath error:nil]) {
            if (![entry.pathExtension isEqualToString:@"app"]) continue;

            NSString *bundlePath = [bucketPath stringByAppendingPathComponent:entry];
            NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (![info isKindOfClass:[NSDictionary class]]) continue;

            NSString *bundleId = info[@"CFBundleIdentifier"];
            if (bundleId.length == 0) continue;
            if ([bundleId hasPrefix:@"com.apple"]) continue;

            NSString *name = info[@"CFBundleDisplayName"];
            if (name.length == 0) name = info[@"CFBundleName"];
            if (name.length == 0) name = entry.stringByDeletingPathExtension;

            NSString *version = info[@"CFBundleShortVersionString"];
            if (version.length == 0) version = info[@"CFBundleVersion"];
            if (version.length == 0) version = @"";

            [out addObject:@{ @"CFBundleIdentifier": bundleId,
                              @"CFBundleDisplayName": name,
                              @"AppBundlePath": bundlePath,
                              @"AppVersion": version }];
        }
    }

    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"CFBundleDisplayName"] localizedCaseInsensitiveCompare:b[@"CFBundleDisplayName"]];
    }];
    return out;
}

#pragma mark -

@interface AppListViewController ()
@property (nonatomic, copy)   NSArray<NSDictionary *> *apps;
@property (nonatomic, copy)   NSArray<NSDictionary *> *filteredApps;
@property (nonatomic, copy)   NSArray<NSDictionary *> *appStoreResults;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSURLSessionDataTask *currentSearchTask;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
@end

@implementation AppListViewController

#pragma mark - Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Select App to Downgrade";
    self.tableView.rowHeight = 60.0;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(forceRefreshApps)];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search App or Paste App Store Link";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.filteredApps = @[];
    self.appStoreResults = @[];

    self.imageCache = [[NSCache alloc] init];
    self.imageCache.countLimit = 100;

    [self loadApps];
}

- (void)forceRefreshApps
{
    gInstalledApps = nil;
    [self loadApps];
}

- (void)loadApps
{
    if (gInstalledApps.count > 0) {
        self.apps = gInstalledApps;
        [self.tableView reloadData];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *apps = applist_scan_installed_apps();
        gInstalledApps = apps;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = apps;
            [self.tableView reloadData];
        });
    });
}

- (BOOL)isFiltering
{
    NSString *text = self.searchController.searchBar.text;
    return self.searchController.isActive && text.length > 0;
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *text = searchController.searchBar.text;

    [self.currentSearchTask cancel];
    self.currentSearchTask = nil;

    if (text.length == 0) {
        self.filteredApps = @[];
        self.appStoreResults = @[];
        [self.tableView reloadData];
        return;
    }

    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
        NSString *name = app[@"CFBundleDisplayName"];
        NSString *bundleId = app[@"CFBundleIdentifier"];
        return [name localizedCaseInsensitiveContainsString:text] ||
               [bundleId localizedCaseInsensitiveContainsString:text];
    }];
    self.filteredApps = [self.apps filteredArrayUsingPredicate:predicate];
    [self.tableView reloadData];

    // Pasting a store link resolves the numeric id directly; anything else is
    // treated as a search term.
    NSString *numericID = nil;
    if ([text localizedCaseInsensitiveContainsString:@"apps.apple.com"] &&
        [text containsString:@"/id"]) {
        NSRange idRange = [text rangeOfString:@"/id"];
        if (idRange.location != NSNotFound) {
            NSString *tail = [text substringFromIndex:NSMaxRange(idRange)];
            NSMutableString *digits = [NSMutableString string];
            for (NSUInteger i = 0; i < tail.length; i++) {
                unichar c = [tail characterAtIndex:i];
                if (c < '0' || c > '9') break;
                [digits appendFormat:@"%C", c];
            }
            if (digits.length > 0) numericID = digits;
        }
    }

    NSString *country = applist_device_country_code();
    NSString *urlString = nil;
    if (numericID.length > 0) {
        urlString = [NSString stringWithFormat:kLookupByIDURL, numericID, country];
    } else {
        NSString *escaped = [text stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
        urlString = [NSString stringWithFormat:kSearchURL, escaped, country];
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10.0;

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:request
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data || error) return;

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) return;

        NSArray *results = json[@"results"];
        if (![results isKindOfClass:[NSArray class]]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.appStoreResults = results;
            [self.tableView reloadData];
        });
    }];
    self.currentSearchTask = task;
    [task resume];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return self.isFiltering ? 2 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.isFiltering) {
        if (section == 0) return (NSInteger)self.filteredApps.count;
        if (section == 1) return (NSInteger)self.appStoreResults.count;
        return 0;
    }
    return (NSInteger)self.apps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (self.isFiltering) {
        if (section == 0) return self.filteredApps.count > 0 ? @"Local Installed Apps" : nil;
        if (section == 1) return self.appStoreResults.count > 0 ? @"App Store Search (Install directly)" : nil;
        return nil;
    }
    return self.apps.count > 0 ? @"Local Installed Apps" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kAppCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kAppCellIdentifier];
    }

    cell.imageView.image = [UIImage systemImageNamed:@"app.dashed"];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (self.isFiltering && indexPath.section == 1) {
        NSDictionary *result = self.appStoreResults[indexPath.row];
        NSString *trackName = result[@"trackName"];
        cell.textLabel.text = trackName.length ? trackName : @"Unknown App";
        cell.detailTextLabel.text = result[@"bundleId"];
        [self loadIconForResult:result cell:cell indexPath:indexPath];
        return cell;
    }

    NSDictionary *app = self.isFiltering ? self.filteredApps[indexPath.row] : self.apps[indexPath.row];
    cell.textLabel.text = app[@"CFBundleDisplayName"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (v%@)",
                                 app[@"CFBundleIdentifier"], app[@"AppVersion"]];
    return cell;
}

- (void)loadIconForResult:(NSDictionary *)result cell:(UITableViewCell *)cell indexPath:(NSIndexPath *)indexPath
{
    NSString *urlString = result[@"artworkUrl100"];
    if (urlString.length == 0) urlString = result[@"artworkUrl60"];
    if (urlString.length == 0) urlString = result[@"artworkUrl512"];
    if (urlString.length == 0) return;

    UIImage *cached = [self.imageCache objectForKey:urlString];
    if (cached) {
        cell.imageView.image = cached;
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlString]
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data.length == 0) return;
        UIImage *image = [UIImage imageWithData:data];
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self.imageCache setObject:image forKey:urlString];
            UITableViewCell *visible = [self.tableView cellForRowAtIndexPath:indexPath];
            if (visible) visible.imageView.image = image;
        });
    }];
    [task resume];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.isFiltering && indexPath.section == 1) {
        NSDictionary *result = self.appStoreResults[indexPath.row];
        NSString *bundleId = result[@"bundleId"];
        if (bundleId.length == 0) return;

        NSMutableDictionary *appInfo = [NSMutableDictionary dictionary];
        appInfo[@"CFBundleIdentifier"] = bundleId;
        appInfo[@"CFBundleDisplayName"] = result[@"trackName"] ?: bundleId;
        if (result[@"trackId"]) appInfo[@"PreFetchedTrackID"] = result[@"trackId"];

        [self presentActionSheetForApp:[appInfo copy] tableView:tableView indexPath:indexPath];
        return;
    }

    NSDictionary *app = self.isFiltering ? self.filteredApps[indexPath.row] : self.apps[indexPath.row];
    [self presentActionSheetForApp:app tableView:tableView indexPath:indexPath];
}

#pragma mark - Track ID

- (void)downgrade_fetchTrackIDWithCountryCodes:(NSArray<NSString *> *)countryCodes
                                         index:(NSUInteger)index
                                      bundleId:(NSString *)bundleId
                                    completion:(void (^)(long long trackID, NSError *error))completion
{
    if (index >= countryCodes.count) {
        NSError *error = [NSError errorWithDomain:kDowngradeErrorDomain
                                             code:404
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        @"App not found in supported App Store regions."}];
        completion(0, error);
        return;
    }

    NSString *country = countryCodes[index];
    NSString *urlString = [NSString stringWithFormat:kLookupByBundleIDURL, bundleId, country];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        completion(0, nil);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10.0;

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:request
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data || error) {
            completion(0, error);
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *results = [json isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
        if ([results isKindOfClass:[NSArray class]] && results.count > 0) {
            long long trackId = [results.firstObject[@"trackId"] longLongValue];
            if (trackId != 0) {
                completion(trackId, nil);
                return;
            }
        }

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self downgrade_fetchTrackIDWithCountryCodes:countryCodes
                                               index:index + 1
                                            bundleId:bundleId
                                          completion:completion];
    }];
    [task resume];
}

- (void)downgrade_fetchTrackIDForBundleID:(NSString *)bundleId
                               completion:(void (^)(long long trackID, NSError *error))completion
{
    [self downgrade_fetchTrackIDWithCountryCodes:applist_supported_country_codes()
                                           index:0
                                        bundleId:bundleId
                                      completion:completion];
}

- (void)downgrade_fetchVersionsForTrackID:(long long)trackID
                               completion:(void (^)(NSArray<NSDictionary *> *versions, NSError *error))completion
{
    NSString *urlString = [NSString stringWithFormat:kHistoryURL, trackID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        completion(nil, nil);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10.0;

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:request
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data || error) {
            completion(nil, error);
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *versions = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        if ([versions isKindOfClass:[NSArray class]] && versions.count > 0) {
            completion(versions, nil);
            return;
        }

        NSError *notFound = [NSError errorWithDomain:kDowngradeErrorDomain
                                                code:404
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           @"No historical versions found."}];
        completion(nil, notFound);
    }];
    [task resume];
}

#pragma mark - Version selection

- (void)downgrade_presentVersionSelection:(NSArray<NSDictionary *> *)versions
                                  trackID:(long long)trackID
                                  appInfo:(NSDictionary *)appInfo
{
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Select Version"
                                            message:@"Choose a version to downgrade to"
                                     preferredStyle:UIAlertControllerStyleAlert];

    NSSortDescriptor *byDate = [NSSortDescriptor sortDescriptorWithKey:@"release_date" ascending:NO];
    NSArray<NSDictionary *> *sorted = [versions sortedArrayUsingDescriptors:@[byDate]];

    for (NSDictionary *version in sorted) {
        NSString *bundleVersion = version[@"bundle_version"];
        if (![bundleVersion isKindOfClass:[NSString class]] || bundleVersion.length == 0) {
            bundleVersion = @"N/A";
        }
        NSString *external = [[version[@"external_identifier"] stringValue] copy];
        if (![external isKindOfClass:[NSString class]]) external = @"";

        NSString *title = external.length > 0
            ? [NSString stringWithFormat:@"%@ (%@)", bundleVersion, external]
            : bundleVersion;

        [alert addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [self runDowngradeWithAppInfo:appInfo
                                trackID:trackID
                              versionId:@(external.longLongValue)];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Entry points

- (void)presentActionSheetForApp:(NSDictionary *)appInfo
                       tableView:(UITableView *)tableView
                       indexPath:(NSIndexPath *)indexPath
{
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"Downgrade/Install Method"
                                            message:@"Choose how to get the version ID"
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Fetch from Server"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self fetchDowngradeDataForApp:appInfo];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Custom Version ID"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self promptForCustomVersionForApp:appInfo];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    sheet.popoverPresentationController.sourceView = tableView;
    sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)fetchDowngradeDataForApp:(NSDictionary *)appInfo
{
    NSString *bundleId = appInfo[@"CFBundleIdentifier"];
    if (bundleId.length == 0) return;

    NSString *displayName = appInfo[@"CFBundleDisplayName"];
    if (displayName.length == 0) displayName = bundleId;

    UIAlertController *loading =
        [UIAlertController alertControllerWithTitle:@"Preparing"
                                            message:[NSString stringWithFormat:@"Fetching Track ID for %@...", displayName]
                                     preferredStyle:UIAlertControllerStyleAlert];

    [self presentViewController:loading animated:YES completion:^{
        [self executeFetchWithBundleId:bundleId appInfo:appInfo loadingAlert:loading];
    }];
}

- (void)executeFetchWithBundleId:(NSString *)bundleId
                         appInfo:(NSDictionary *)appInfo
                    loadingAlert:(UIAlertController *)loadingAlert
{
    __block BOOL settled = NO;

    void (^finish)(void) = ^{
        if (settled) return;
        settled = YES;
        [loadingAlert dismissViewControllerAnimated:YES completion:nil];
    };

    // The history endpoint is occasionally slow; give the whole chain 15s
    // before telling the user it failed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (settled) return;
        settled = YES;
        [loadingAlert dismissViewControllerAnimated:YES completion:^{
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:@"Timeout"
                                                    message:@"Failed to fetch data within 15 seconds."
                                             preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Retry"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *action) {
                [self fetchDowngradeDataForApp:appInfo];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        }];
    });

    void (^fetchVersions)(long long) = ^(long long trackId) {
        [self downgrade_fetchVersionsForTrackID:trackId
                                     completion:^(NSArray<NSDictionary *> *versions, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (settled) return;
                finish();

                if (versions.count == 0) {
                    UIAlertController *alert =
                        [UIAlertController alertControllerWithTitle:@"Error"
                                                            message:error.localizedDescription ?: @"Failed to get versions"
                                                     preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                              style:UIAlertActionStyleCancel
                                                            handler:nil]];
                    [alert addAction:[UIAlertAction actionWithTitle:@"Retry"
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction *action) {
                        [self fetchDowngradeDataForApp:appInfo];
                    }]];
                    [self presentViewController:alert animated:YES completion:nil];
                    return;
                }

                [self downgrade_presentVersionSelection:versions trackID:trackId appInfo:appInfo];
            });
        }];
    };

    NSNumber *preFetched = appInfo[@"PreFetchedTrackID"];
    if ([preFetched isKindOfClass:[NSNumber class]] || [preFetched isKindOfClass:[NSString class]]) {
        fetchVersions([preFetched longLongValue]);
        return;
    }

    [self downgrade_fetchTrackIDForBundleID:bundleId
                                 completion:^(long long trackID, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (settled) return;

            if (trackID == 0) {
                finish();
                UIAlertController *alert =
                    [UIAlertController alertControllerWithTitle:@"Error"
                                                        message:error.localizedDescription ?: @"Could not fetch the Track ID for this app."
                                                 preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil]];
                [alert addAction:[UIAlertAction actionWithTitle:@"Retry"
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *action) {
                    [self fetchDowngradeDataForApp:appInfo];
                }]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }

            fetchVersions(trackID);
        });
    }];
}

- (void)promptForCustomVersionForApp:(NSDictionary *)appInfo
{
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Custom Version ID"
                                            message:@"Enter the numeric AppExtVrsId for the version:\ne.g., 843219482"
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.placeholder = @"Version ID";
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Downgrade"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text;
        long long versionId = text.longLongValue;
        if (versionId == 0) return;
        [self executeCustomDowngradeWithAppInfo:appInfo versionId:@(versionId)];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)executeCustomDowngradeWithAppInfo:(NSDictionary *)appInfo versionId:(NSNumber *)versionId
{
    NSString *bundleId = appInfo[@"CFBundleIdentifier"];
    if (bundleId.length == 0) return;

    NSString *displayName = appInfo[@"CFBundleDisplayName"];
    if (displayName.length == 0) displayName = appInfo[@"CFBundleName"];
    if (displayName.length == 0) displayName = bundleId;

    UIAlertController *preparing =
        [UIAlertController alertControllerWithTitle:@"Preparing"
                                            message:[NSString stringWithFormat:@"Fetching Track ID for %@...", displayName]
                                     preferredStyle:UIAlertControllerStyleAlert];

    [self presentViewController:preparing animated:YES completion:^{
        NSNumber *preFetched = appInfo[@"PreFetchedTrackID"];
        if ([preFetched isKindOfClass:[NSNumber class]] || [preFetched isKindOfClass:[NSString class]]) {
            long long trackId = [preFetched longLongValue];
            [preparing dismissViewControllerAnimated:YES completion:^{
                [self runDowngradeWithAppInfo:appInfo trackID:trackId versionId:versionId];
            }];
            return;
        }

        [self downgrade_fetchTrackIDForBundleID:bundleId
                                     completion:^(long long trackID, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [preparing dismissViewControllerAnimated:YES completion:^{
                    if (trackID == 0) {
                        UIAlertController *alert =
                            [UIAlertController alertControllerWithTitle:@"Error"
                                                                message:error.localizedDescription ?: @"Could not fetch the Track ID for this app."
                                                         preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                  style:UIAlertActionStyleCancel
                                                                handler:nil]];
                        [self presentViewController:alert animated:YES completion:nil];
                        return;
                    }
                    [self runDowngradeWithAppInfo:appInfo trackID:trackID versionId:versionId];
                }];
            });
        }];
    }];
}

// Opens the shared progress screen so the payload's log lines are visible,
// then hands the request to SpringBoard once the screen is on screen.
- (void)runDowngradeWithAppInfo:(NSDictionary *)appInfo
                        trackID:(long long)trackID
                      versionId:(NSNumber *)versionId
{
    NSString *bundleId = appInfo[@"CFBundleIdentifier"];
    if (bundleId.length == 0) return;

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"CFBundleIdentifier"] = bundleId;
    payload[@"CFBundleDisplayName"] = appInfo[@"CFBundleDisplayName"] ?: bundleId;
    payload[@"trackId"] = @(trackID);

    InstallProgressViewController *vc = [[InstallProgressViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationAutomatic;
    [self presentViewController:nav animated:YES completion:^{
        app_downgrade_trigger_in_springboard([payload copy], versionId);
    }];
}

@end
