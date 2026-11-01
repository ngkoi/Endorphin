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

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationType;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) BOOL isPlaceholder;
@property (nonatomic, readonly) BOOL isLaunchProhibited;
- (NSData *)iconDataForVariant:(int)variant;
+ (LSApplicationProxy *)applicationProxyForIdentifier:(NSString *)identifier;
@end

@interface DOAppItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *appFolderName;
@property (nonatomic, strong, nullable) UIImage *icon;
@end

@implementation DOAppItem
@end

@interface DOStealthAppListController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) NSArray<DOAppItem *> *allApps;
@property (nonatomic, strong) NSArray<DOAppItem *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedItems;
@end

@implementation DOStealthAppListController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [DOPSListController setupViewControllerStyle:self];

    self.selectedItems = [NSMutableSet set];
    NSArray *saved = [[DOPreferenceManager sharedManager] preferenceValueForKey:@"stealthApps"];
    if (saved) {
        [self.selectedItems addObjectsFromArray:saved];
    }

    UIView *header = [DOPSListItemsController makeHeader:@"Stealth Apps" withTarget:self];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search applications";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.barStyle = UIBarStyleBlack;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.rowHeight = 60.0;
    [self.view addSubview:self.tableView];

    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.color = [UIColor whiteColor];
    self.activityIndicator.hidesWhenStopped = YES;
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.activityIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:5],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:70],

        [self.searchBar.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:5],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.searchBar.heightAnchor constraintEqualToConstant:44],

        [self.tableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:10],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-10],

        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    [self.activityIndicator startAnimating];
    [self loadInstalledApplications];
}

- (void)dismiss
{
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)loadInstalledApplications
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray<DOAppItem *> *appsList = [NSMutableArray array];

        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (workspaceClass) {
            id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
            NSArray *installed = nil;
            if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
                installed = [workspace performSelector:@selector(allInstalledApplications)];
            } else if ([workspace respondsToSelector:@selector(allApplications)]) {
                installed = [workspace performSelector:@selector(allApplications)];
            }

            for (id proxy in installed) {
                if ([proxy respondsToSelector:@selector(isPlaceholder)] && [proxy isPlaceholder]) continue;
                if ([proxy respondsToSelector:@selector(isLaunchProhibited)] && [proxy isLaunchProhibited]) continue;

                NSString *appType = [proxy respondsToSelector:@selector(applicationType)] ? [proxy applicationType] : nil;
                // Exclude system daemons; focus on User and System apps that can be launched
                if (appType && [appType isEqualToString:@"PluginKit"]) continue;

                NSString *bid = [proxy respondsToSelector:@selector(bundleIdentifier)] ? [proxy bundleIdentifier] : nil;
                NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy localizedName] : nil;
                NSURL *bundleURL = [proxy respondsToSelector:@selector(bundleURL)] ? [proxy bundleURL] : nil;

                if (!bid || bid.length == 0) continue;
                if (!name || name.length == 0) name = bid;

                DOAppItem *item = [[DOAppItem alloc] init];
                item.bundleID = bid;
                item.name = name;
                item.appFolderName = bundleURL ? bundleURL.lastPathComponent : nil;

                UIImage *iconImage = nil;
                @try {
                    Class lsProxyClass = NSClassFromString(@"LSApplicationProxy");
                    if (lsProxyClass) {
                        id p = [lsProxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:bid];
                        if (p && [p respondsToSelector:@selector(iconDataForVariant:)]) {
                            for (int v = 2; v <= 5; v++) {
                                id data = [p performSelector:@selector(iconDataForVariant:) withObject:@(v)];
                                if (data && [data isKindOfClass:[NSData class]]) {
                                    iconImage = [UIImage imageWithData:data scale:[UIScreen mainScreen].scale];
                                    if (iconImage) break;
                                }
                            }
                        }
                    }
                } @catch (NSException *e) {}

                if (!iconImage) {
                    SEL iconSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
                    if ([UIImage respondsToSelector:iconSel]) {
                        typedef UIImage *(*IconFunc)(id, SEL, NSString *, int, CGFloat);
                        IconFunc func = (IconFunc)[UIImage methodForSelector:iconSel];
                        iconImage = func([UIImage class], iconSel, bid, 0, [UIScreen mainScreen].scale);
                    }
                }

                item.icon = iconImage;
                [appsList addObject:item];
            }
        }

        [appsList sortUsingComparator:^NSComparisonResult(DOAppItem *a, DOAppItem *b) {
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            self.allApps = appsList;
            self.filteredApps = appsList;
            [self.tableView reloadData];
        });
    });
}

#pragma mark - Search Bar Delegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    if (searchText.length == 0) {
        self.filteredApps = self.allApps;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@ OR bundleID CONTAINS[cd] %@", searchText, searchText];
        self.filteredApps = [self.allApps filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
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
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
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
    toggle.tag = indexPath.row;
    toggle.on = [self.selectedItems containsObject:item.bundleID];

    return cell;
}

- (void)appSwitchToggled:(UISwitch *)sender
{
    NSInteger row = sender.tag;
    if (row < 0 || row >= self.filteredApps.count) return;

    DOAppItem *item = self.filteredApps[row];
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
