//
//  DOPSListController.m
//  Dopamine
//
//  Created by tomt000 on 26/01/2024.
//

#import "DOPSListController.h"
#import "DOThemeManager.h"

@interface DOPSListController ()

@end

@implementation DOPSListController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [_table setSeparatorColor:[UIColor clearColor]];
    [_table setBackgroundColor:[UIColor clearColor]];
    [DOPSListController setupViewControllerStyle:self];
}

+ (void)setupViewControllerStyle:(UIViewController*)vc
{
    DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];
    
    vc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    vc.view.backgroundColor = theme.windowColor;
    vc.view.layer.cornerRadius = 16;
    vc.view.layer.masksToBounds = YES;
    vc.view.layer.cornerCurve = kCACornerCurveContinuous;
    
    if (@available(iOS 19.0, *)) {
        // Apple broke the method below by reimplementing some Preferences.framework classes in SwiftUI
        // Now onTintColor is only implemented when the cell is initialized but gets reset to the stock color when the cell is reused
    }
    else {
        UIColor *tintColor = [theme.key isEqualToString:@"aqua"] ?
            [UIColor colorWithRed:32.0/255.0 green:135.0/255.0 blue:226.0/255.0 alpha:1.0] :
            [UIColor colorWithRed:255.0/255.0 green:49.0/255.0 blue:49.0/255.0 alpha:1.0];
        [UISwitch appearanceWhenContainedInInstancesOfClasses:@[[vc class]]].onTintColor = tintColor;
    }
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    cell.backgroundColor = [UIColor clearColor];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _table.frame = CGRectMake(12, 5, self.view.bounds.size.width - 24, self.view.bounds.size.height - 10);
}

#pragma mark - Status Bar

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}


@end
