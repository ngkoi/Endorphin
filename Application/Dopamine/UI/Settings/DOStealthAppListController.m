//
//  DOStealthAppListController.m
//  Endorphin
//
//  Created for Endorphin Jailbreak.
//

#import "DOStealthAppListController.h"
#import "DOPSListController.h"
#import "DOPSListItemsController.h"
#import "DOPreferenceManager.h"
#import "DOSettingsController.h"
#import "DOEnvironmentManager.h"
#import "DOThemeManager.h"
#import <objc/runtime.h>
#import <dlfcn.h>

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationType;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) BOOL isPlaceholder;
@property (nonatomic, readonly) BOOL isLaunchProhibited;
+ (LSApplicationProxy *)applicationProxyForIdentifier:(NSString *)identifier;
@end

@interface LSApplicationWorkspace : NSObject
+ (LSApplicationWorkspace *)defaultWorkspace;
- (void)enumerateApplicationsOfType:(NSUInteger)type block:(void (^)(LSApplicationProxy *proxy))block;
- (NSArray *)allInstalledApplications;
- (NSArray *)allApplications;
@end

@interface UINavigationController (Private)
- (CGRect)_frameForViewController:(id)viewController;
@end

@interface DOAppItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy, nullable) NSString *appFolderName;
@property (nonatomic, strong, nullable) NSURL *bundleURL;
@property (nonatomic, strong, nullable) UIImage *icon;
@end

@implementation DOAppItem
@end

@interface DOStealthAppListController ()
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSArray<DOAppItem *> *allApps;
@property (nonatomic, strong) NSArray<DOAppItem *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedItems;
@end

@implementation DOStealthAppListController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:24.0/255.0 green:24.0/255.0 blue:28.0/255.0 alpha:1.0];

    self.selectedItems = [NSMutableSet set];
    NSArray *saved = [[DOPreferenceManager sharedManager] preferenceValueForKey:@"stealthApps"];
    if (saved) {
        [self.selectedItems addObjectsFromArray:saved];
    }

    self.headerView = [self buildHeaderView];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.headerView];

    DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];
    UIColor *accentColor = [theme.key isEqualToString:@"aqua"] ?
        [UIColor colorWithRed:32.0/255.0 green:135.0/255.0 blue:226.0/255.0 alpha:1.0] :
        [UIColor colorWithRed:255.0/255.0 green:49.0/255.0 blue:49.0/255.0 alpha:1.0];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search applications";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.barStyle = UIBarStyleBlack;
    self.searchBar.tintColor = accentColor;
    if (@available(iOS 13.0, *)) {
        self.searchBar.searchTextField.textColor = [UIColor whiteColor];
    }
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight = 60.0;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.emptyLabel.text = @"No applications found";
    self.emptyLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.4];
    self.emptyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.hidden = YES;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];

    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.color = [UIColor whiteColor];
    self.activityIndicator.hidesWhenStopped = YES;
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.activityIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:56],

        [self.searchBar.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.searchBar.heightAnchor constraintEqualToConstant:44],

        [self.tableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    [self.activityIndicator startAnimating];
    [self loadInstalledApplications];
}

- (UIView *)buildHeaderView
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Stealth Apps";
    titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.textAlignment = NSTextAlignmentLeft;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = @"Selected apps run without tweak injection";
    subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:subtitleLabel];

    UIButton *doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [doneButton setTitle:@"Done" forState:UIControlStateNormal];
    doneButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];
    UIColor *accentColor = [theme.key isEqualToString:@"aqua"] ?
        [UIColor colorWithRed:32.0/255.0 green:135.0/255.0 blue:226.0/255.0 alpha:1.0] :
        [UIColor colorWithRed:255.0/255.0 green:49.0/255.0 blue:49.0/255.0 alpha:1.0];
    doneButton.tintColor = accentColor;
    [doneButton addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    doneButton.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:doneButton];

    UIView *separator = [[UIView alloc] init];
    separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:separator];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [titleLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],

        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],

        [doneButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [doneButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],

        [separator.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5],
    ]];

    return header;
}

- (void)dismiss
{
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)loadInstalledApplications
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableDictionary<NSString *, DOAppItem *> *appsDict = [NSMutableDictionary dictionary];

        // 1. Try LaunchServices
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);

        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (workspaceClass) {
            id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
            if (workspace) {
                void (^processProxy)(id) = ^(id proxy) {
                    if (!proxy) return;
                    if ([proxy respondsToSelector:@selector(isPlaceholder)] && [proxy isPlaceholder]) return;
                    if ([proxy respondsToSelector:@selector(isLaunchProhibited)] && [proxy isLaunchProhibited]) return;

                    NSString *appType = [proxy respondsToSelector:@selector(applicationType)] ? [proxy applicationType] : nil;
                    if (appType && [appType isEqualToString:@"PluginKit"]) return;

                    NSString *bid = [proxy respondsToSelector:@selector(bundleIdentifier)] ? [proxy bundleIdentifier] : nil;
                    NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy localizedName] : nil;
                    NSURL *bundleURL = [proxy respondsToSelector:@selector(bundleURL)] ? [proxy bundleURL] : nil;

                    if (!bid || bid.length == 0) return;
                    if (!name || name.length == 0) name = bid;

                    DOAppItem *item = [[DOAppItem alloc] init];
                    item.bundleID = bid;
                    item.name = name;
                    item.bundleURL = bundleURL;
                    item.appFolderName = bundleURL ? bundleURL.lastPathComponent : nil;

                    appsDict[bid] = item;
                };

                // In iOS 14, 15, 16: enumerateApplicationsOfType:block: is the true SPI
                // Type 0 = User Applications (App Store, Sideloaded, TrollStore)
                // Type 1 = System Applications
                if ([workspace respondsToSelector:@selector(enumerateApplicationsOfType:block:)]) {
                    [workspace enumerateApplicationsOfType:0 block:processProxy];
                    [workspace enumerateApplicationsOfType:1 block:processProxy];
                }

                // Fallbacks if enumerateApplicationsOfType:block: did not populate
                if (appsDict.count == 0 && [workspace respondsToSelector:@selector(allInstalledApplications)]) {
                    NSArray *installed = [workspace performSelector:@selector(allInstalledApplications)];
                    for (id proxy in installed) {
                        processProxy(proxy);
                    }
                }
                if (appsDict.count == 0 && [workspace respondsToSelector:@selector(allApplications)]) {
                    NSArray *allApps = [workspace performSelector:@selector(allApplications)];
                    for (id proxy in allApps) {
                        processProxy(proxy);
                    }
                }
            }
        }

        // 2. Scan /private/var/containers/Bundle/Application (User Apps: VNeID, Banking, etc.)
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *userAppsDir = @"/private/var/containers/Bundle/Application";
        NSArray *uuids = [fm contentsOfDirectoryAtPath:userAppsDir error:nil];
        for (NSString *uuid in uuids) {
            NSString *bundleFolder = [userAppsDir stringByAppendingPathComponent:uuid];
            NSArray *subItems = [fm contentsOfDirectoryAtPath:bundleFolder error:nil];
            for (NSString *subItem in subItems) {
                if ([subItem.pathExtension isEqualToString:@"app"]) {
                    NSString *appPath = [bundleFolder stringByAppendingPathComponent:subItem];
                    NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                    if (info) {
                        NSString *bid = info[@"CFBundleIdentifier"];
                        if (bid && bid.length > 0) {
                            DOAppItem *existing = appsDict[bid];
                            if (!existing) {
                                DOAppItem *item = [[DOAppItem alloc] init];
                                item.bundleID = bid;
                                NSString *displayName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
                                item.name = (displayName && displayName.length > 0) ? displayName : [subItem stringByDeletingPathExtension];
                                item.bundleURL = [NSURL fileURLWithPath:appPath];
                                item.appFolderName = subItem;
                                appsDict[bid] = item;
                            } else {
                                if (!existing.bundleURL) {
                                    existing.bundleURL = [NSURL fileURLWithPath:appPath];
                                }
                                if (!existing.appFolderName) {
                                    existing.appFolderName = subItem;
                                }
                            }
                        }
                    }
                }
            }
        }

        // 3. Scan System Apps: /Applications and /System/Applications
        NSArray *sysDirs = @[@"/Applications", @"/System/Applications"];
        for (NSString *sysDir in sysDirs) {
            NSArray *apps = [fm contentsOfDirectoryAtPath:sysDir error:nil];
            for (NSString *appFolder in apps) {
                if ([appFolder.pathExtension isEqualToString:@"app"]) {
                    NSString *appPath = [sysDir stringByAppendingPathComponent:appFolder];
                    NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                    if (info) {
                        NSString *bid = info[@"CFBundleIdentifier"];
                        if (bid && bid.length > 0 && !appsDict[bid]) {
                            DOAppItem *item = [[DOAppItem alloc] init];
                            item.bundleID = bid;
                            NSString *displayName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
                            item.name = (displayName && displayName.length > 0) ? displayName : [appFolder stringByDeletingPathExtension];
                            item.bundleURL = [NSURL fileURLWithPath:appPath];
                            item.appFolderName = appFolder;
                            appsDict[bid] = item;
                        }
                    }
                }
            }
        }

        // 4. Sort alphabetically
        NSArray<DOAppItem *> *sortedApps = [[appsDict allValues] sortedArrayUsingComparator:^NSComparisonResult(DOAppItem *a, DOAppItem *b) {
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];

        // Preload and resize icons for all apps in background
        for (DOAppItem *item in sortedApps) {
            item.icon = [self iconForItem:item];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            self.allApps = sortedApps;
            self.filteredApps = sortedApps;
            self.emptyLabel.hidden = (sortedApps.count > 0);
            [self.tableView reloadData];
        });
    });
}

- (UIImage *)resizeIcon:(UIImage *)image
{
    if (!image) return nil;
    CGSize targetSize = CGSizeMake(40, 40);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    }];
}

- (UIImage *)iconForItem:(DOAppItem *)item
{
    UIImage *iconImage = nil;

    // 1. Try UIImage private API with scale
    SEL iconSelScale = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage respondsToSelector:iconSelScale]) {
        typedef UIImage *(*IconFuncScale)(id, SEL, NSString *, int, CGFloat);
        IconFuncScale func = (IconFuncScale)[UIImage methodForSelector:iconSelScale];
        iconImage = func([UIImage class], iconSelScale, item.bundleID, 2, [UIScreen mainScreen].scale);
        if (!iconImage) {
            iconImage = func([UIImage class], iconSelScale, item.bundleID, 0, [UIScreen mainScreen].scale);
        }
        if (iconImage) return [self resizeIcon:iconImage];
    }

    // 2. Try UIImage private API without scale
    SEL iconSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:");
    if ([UIImage respondsToSelector:iconSel]) {
        typedef UIImage *(*IconFunc)(id, SEL, NSString *, int);
        IconFunc func = (IconFunc)[UIImage methodForSelector:iconSel];
        iconImage = func([UIImage class], iconSel, item.bundleID, 2);
        if (!iconImage) {
            iconImage = func([UIImage class], iconSel, item.bundleID, 0);
        }
        if (iconImage) return [self resizeIcon:iconImage];
    }

    // 3. Try reading icon file from bundle directory
    if (item.bundleURL) {
        NSString *bundlePath = item.bundleURL.path;
        NSFileManager *fm = [NSFileManager defaultManager];

        // 3a. Check Info.plist
        NSString *infoPlist = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
        if (dict) {
            NSMutableArray *iconCandidates = [NSMutableArray array];
            NSArray *primaryFiles = dict[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
            if (primaryFiles && [primaryFiles isKindOfClass:[NSArray class]]) {
                [iconCandidates addObjectsFromArray:primaryFiles];
            }
            NSArray *ipadFiles = dict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
            if (ipadFiles && [ipadFiles isKindOfClass:[NSArray class]]) {
                [iconCandidates addObjectsFromArray:ipadFiles];
            }
            NSArray *rootFiles = dict[@"CFBundleIconFiles"];
            if (rootFiles && [rootFiles isKindOfClass:[NSArray class]]) {
                [iconCandidates addObjectsFromArray:rootFiles];
            }
            NSString *singleFile = dict[@"CFBundleIconFile"];
            if (singleFile && [singleFile isKindOfClass:[NSString class]]) {
                [iconCandidates addObject:singleFile];
            }

            for (NSString *iconName in iconCandidates) {
                if (![iconName isKindOfClass:[NSString class]]) continue;
                NSArray *suffixes = @[@"@3x.png", @"@2x.png", @".png", @""];
                for (NSString *sfx in suffixes) {
                    NSString *nameWithSfx = [iconName hasSuffix:@".png"] ? iconName : [iconName stringByAppendingString:sfx];
                    NSString *full = [bundlePath stringByAppendingPathComponent:nameWithSfx];
                    if ([fm fileExistsAtPath:full]) {
                        iconImage = [UIImage imageWithContentsOfFile:full];
                        if (iconImage) return [self resizeIcon:iconImage];
                    }
                }
            }
        }

        // 3b. Common fixed names in bundle root
        NSArray *wellKnownNames = @[
            @"AppIcon60x60@2x.png",
            @"AppIcon60x60@3x.png",
            @"AppIcon76x76@2x~ipad.png",
            @"AppIcon-60x60@2x.png",
            @"AppIcon40x40@2x.png",
            @"AppIcon40x40@3x.png",
            @"icon@2x.png",
            @"icon@3x.png",
            @"icon.png"
        ];
        for (NSString *known in wellKnownNames) {
            NSString *full = [bundlePath stringByAppendingPathComponent:known];
            if ([fm fileExistsAtPath:full]) {
                iconImage = [UIImage imageWithContentsOfFile:full];
                if (iconImage) return [self resizeIcon:iconImage];
            }
        }

        // 3c. Enumerate bundle directory files for any AppIcon png
        NSArray *files = [fm contentsOfDirectoryAtPath:bundlePath error:nil];
        NSString *bestMatch = nil;
        for (NSString *file in files) {
            if ([file.pathExtension.lowercaseString isEqualToString:@"png"]) {
                NSString *lower = file.lowercaseString;
                if ([lower containsString:@"appicon"]) {
                    if ([lower containsString:@"@3x"]) {
                        bestMatch = file;
                        break;
                    } else if ([lower containsString:@"@2x"]) {
                        bestMatch = file;
                    } else if (!bestMatch) {
                        bestMatch = file;
                    }
                } else if (!bestMatch && [lower containsString:@"icon"]) {
                    bestMatch = file;
                }
            }
        }
        if (bestMatch) {
            NSString *full = [bundlePath stringByAppendingPathComponent:bestMatch];
            iconImage = [UIImage imageWithContentsOfFile:full];
            if (iconImage) return [self resizeIcon:iconImage];
        }
    }

    return nil;
}

#pragma mark - Search Bar Delegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    NSString *trimmed = [searchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        self.filteredApps = self.allApps;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@ OR bundleID CONTAINS[cd] %@", trimmed, trimmed];
        self.filteredApps = [self.allApps filteredArrayUsingPredicate:predicate];
    }
    self.emptyLabel.hidden = (self.filteredApps.count > 0);
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    [self.searchBar resignFirstResponder];
}

#pragma mark - Table View Data Source & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *cellID = @"StealthAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;

        UIView *selectedBg = [[UIView alloc] init];
        selectedBg.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        cell.selectedBackgroundView = selectedBg;

        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];

        cell.imageView.layer.cornerRadius = 8.0;
        cell.imageView.layer.masksToBounds = YES;

        UISwitch *toggle = [[UISwitch alloc] init];
        DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];
        toggle.onTintColor = [theme.key isEqualToString:@"aqua"] ?
            [UIColor colorWithRed:32.0/255.0 green:135.0/255.0 blue:226.0/255.0 alpha:1.0] :
            [UIColor colorWithRed:255.0/255.0 green:49.0/255.0 blue:49.0/255.0 alpha:1.0];
        [toggle addTarget:self action:@selector(appSwitchToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }

    DOAppItem *item = self.filteredApps[indexPath.row];
    cell.textLabel.text = item.name;
    cell.detailTextLabel.text = item.bundleID;

    if (item.icon) {
        cell.imageView.image = item.icon;
    } else {
        cell.imageView.image = [UIImage systemImageNamed:@"app.fill"];
        cell.imageView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.4];
    }

    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    objc_setAssociatedObject(toggle, "appItem", item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    toggle.on = [self.selectedItems containsObject:item.bundleID];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (cell && [cell.accessoryView isKindOfClass:[UISwitch class]]) {
        UISwitch *toggle = (UISwitch *)cell.accessoryView;
        [toggle setOn:!toggle.isOn animated:YES];
        [self appSwitchToggled:toggle];
    }
}

- (void)appSwitchToggled:(UISwitch *)sender
{
    DOAppItem *item = objc_getAssociatedObject(sender, "appItem");
    if (!item || !item.bundleID) return;

    if (sender.isOn) {
        [self.selectedItems addObject:item.bundleID];
        if (item.appFolderName && item.appFolderName.length > 0) {
            [self.selectedItems addObject:item.appFolderName];
        }
    } else {
        [self.selectedItems removeObject:item.bundleID];
        if (item.appFolderName && item.appFolderName.length > 0) {
            [self.selectedItems removeObject:item.appFolderName];
        }
    }

    NSArray *savedArray = [self.selectedItems allObjects];
    [[DOPreferenceManager sharedManager] setPreferenceValue:savedArray forKey:@"stealthApps"];
    [DOSettingsController syncEndorphinBaseBinConfig];
}

@end
