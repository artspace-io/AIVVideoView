import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // AIVVideoView_Tests 是 hosted 在这个 app 里跑的（CocoaPods `inherit! :search_paths` 依赖宿主 app
        // 已经 embed 好的 framework）。真的把 HomeViewController 起起来会让它里面的
        // AIVCellPlaybackController 在后台真实调用 AIVVideoPlayerCoordinator.shared，
        // 污染测试用例里对同一个单例的状态假设，所以测试运行时直接跳过正常 UI 启动。
        guard NSClassFromString("XCTestCase") == nil else { return true }

        UINavigationBar.appearance().barStyle = .black
        UINavigationBar.appearance().tintColor = .white
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.white]

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UINavigationController(rootViewController: HomeViewController())
        window?.makeKeyAndVisible()
        return true
    }
}
