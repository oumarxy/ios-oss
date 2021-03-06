import Crashlytics
import Fabric
import FBSDKCoreKit
import Foundation
import HockeySDK
#if DEBUG
  @testable import KsApi
#else
  import KsApi
#endif
import Kickstarter_Framework
import Library
import LiveStream
import Prelude
import ReactiveExtensions
import ReactiveSwift
import Result
import SafariServices
import UIKit
import UserNotifications

@UIApplicationMain
internal final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  fileprivate let viewModel: AppDelegateViewModelType = AppDelegateViewModel()

  internal var rootTabBarController: RootTabBarViewController? {
    return self.window?.rootViewController as? RootTabBarViewController
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {

    UIView.doBadSwizzleStuff()
    UIViewController.doBadSwizzleStuff()

    AppEnvironment.replaceCurrentEnvironment(
      AppEnvironment.fromStorage(
        ubiquitousStore: NSUbiquitousKeyValueStore.default,
        userDefaults: UserDefaults.standard
      )
    )

    // NB: We have to push this shared instance directly because somehow we get two different shared
    //     instances if we use the one from `Environment.init`.
    AppEnvironment.replaceCurrentEnvironment(facebookAppDelegate: FBSDKApplicationDelegate.sharedInstance())

    #if DEBUG
      if KsApi.Secrets.isOSS {
        AppEnvironment.replaceCurrentEnvironment(apiService: MockService())
      }
    #endif

    self.viewModel.outputs.updateCurrentUserInEnvironment
      .observeForUI()
      .observeValues { [weak self] user in
        AppEnvironment.updateCurrentUser(user)
        self?.viewModel.inputs.currentUserUpdatedInEnvironment()
    }

    self.viewModel.outputs.forceLogout
      .observeForUI()
      .observeValues {
        AppEnvironment.logout()
        NotificationCenter.default.post(.init(name: .ksr_sessionEnded, object: nil))
    }

    self.viewModel.outputs.updateConfigInEnvironment
      .observeForUI()
      .observeValues { AppEnvironment.updateConfig($0) }

    self.viewModel.outputs.postNotification
      .observeForUI()
      .observeValues(NotificationCenter.default.post)

    self.viewModel.outputs.presentViewController
      .observeForUI()
      .observeValues { [weak self] in
        self?.rootTabBarController?.dismiss(animated: true, completion: nil)
        self?.rootTabBarController?.present($0, animated: true, completion: nil)
    }

    self.viewModel.outputs.goToDiscovery
      .observeForUI()
      .observeValues { [weak self] in self?.rootTabBarController?.switchToDiscovery(params: $0) }

    self.viewModel.outputs.goToActivity
      .observeForUI()
      .observeValues { [weak self] in self?.rootTabBarController?.switchToActivities() }

    self.viewModel.outputs.goToDashboard
      .observeForUI()
      .observeValues { [weak self] in self?.rootTabBarController?.switchToDashboard(project: $0) }

    self.viewModel.outputs.goToLiveStream
      .observeForControllerAction()
      .observeValues { [weak self] in
        self?.goToLiveStream(project: $0, liveStreamEvent: $1, refTag: $2)
    }

    self.viewModel.outputs.goToCreatorMessageThread
      .observeForUI()
      .observeValues { [weak self] in
        self?.goToCreatorMessageThread($0, $1)
      }

    self.viewModel.outputs.goToMessageThread
      .observeForUI()
      .observeValues { [weak self] in self?.goToMessageThread($0) }

    self.viewModel.outputs.goToProjectActivities
      .observeForUI()
      .observeValues { [weak self] in
        self?.goToProjectActivities($0)
    }

    self.viewModel.outputs.goToSearch
      .observeForUI()
      .observeValues { [weak self] in self?.rootTabBarController?.switchToSearch() }

    self.viewModel.outputs.goToMobileSafari
      .observeForUI()
      .observeValues { UIApplication.shared.openURL($0) }

    self.viewModel.outputs.registerForRemoteNotifications
      .observeForUI()
      .observeValues {
        if #available(iOS 10.0, *) {
          UIApplication.shared.registerForRemoteNotifications()
        } else {
          UIApplication.shared.registerUserNotificationSettings(
            UIUserNotificationSettings(types: .alert, categories: [])
          )

          UIApplication.shared.registerForRemoteNotifications()
        }
      }

      if #available(iOS 10.0, *) {
        self.viewModel.outputs.getNotificationAuthorizationStatus
          .observeForUI()
          .observeValues { [weak self] in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
              self?.viewModel.inputs.notificationAuthorizationStatusReceived(settings.authorizationStatus)
            }
          }

        self.viewModel.outputs.authorizeForRemoteNotifications
          .observeForUI()
          .observeValues { [weak self] in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { (isGranted, _) in
              self?.viewModel.inputs.notificationAuthorizationCompleted(isGranted: isGranted)
            }
          }
      }

    self.viewModel.outputs.showAlert
      .observeForUI()
      .observeValues { [weak self] in
        self?.presentContextualPermissionAlert($0)
    }

    self.viewModel.outputs.unregisterForRemoteNotifications
      .observeForUI()
      .observeValues(UIApplication.shared.unregisterForRemoteNotifications)

    self.viewModel.outputs.presentRemoteNotificationAlert
      .observeForUI()
      .observeValues { [weak self] in
        self?.presentRemoteNotificationAlert($0)
      }

    #if RELEASE || HOCKEY
    self.viewModel.outputs.configureFabric
      .observeForUI()
      .observeValues {
        Fabric.with([Crashlytics.self])
    }
    #endif

    self.viewModel.outputs.configureHockey
      .observeForUI()
      .observeValues { [weak self] data in
        guard let _self = self else { return }
        let manager = BITHockeyManager.shared()
        manager.delegate = _self
        manager.configure(withIdentifier: data.appIdentifier)
        manager.crashManager.crashManagerStatus = .autoSend
        manager.isUpdateManagerDisabled = data.disableUpdates
        manager.userID = data.userId
        manager.userName = data.userName
        manager.start()
        manager.authenticator.authenticateInstallation()
    }

    self.viewModel.outputs.synchronizeUbiquitousStore
      .observeForUI()
      .observeValues {
        _ = AppEnvironment.current.ubiquitousStore.synchronize()
    }

    self.viewModel.outputs.setApplicationShortcutItems
      .observeForUI()
      .observeValues { shortcutItems in
        UIApplication.shared.shortcutItems = shortcutItems.map { $0.applicationShortcutItem }
    }

    self.viewModel.outputs.findRedirectUrl
      .observeForUI()
      .observeValues { [weak self] in self?.findRedirectUrl($0) }

    //swiftlint:disable discarded_notification_center_observer
    NotificationCenter.default
      .addObserver(forName: Notification.Name.ksr_sessionStarted, object: nil, queue: nil) { [weak self] _ in
        self?.viewModel.inputs.userSessionStarted()
    }

    NotificationCenter.default
      .addObserver(
        forName: Notification.Name.ksr_showNotificationsDialog, object: nil, queue: nil) { [weak self] in
        self?.viewModel.inputs.showNotificationDialog(notification: $0)
    }

    NotificationCenter.default
      .addObserver(forName: Notification.Name.ksr_sessionEnded, object: nil, queue: nil) { [weak self] _ in
        self?.viewModel.inputs.userSessionEnded()
    }
    //swiftlint:enable discarded_notification_center_observer

    self.window?.tintColor = .ksr_dark_grey_500

    self.viewModel.inputs.applicationDidFinishLaunching(application: application,
                                                        launchOptions: launchOptions)

    return self.viewModel.outputs.applicationDidFinishLaunchingReturnValue
  }

  func applicationWillEnterForeground(_ application: UIApplication) {
    self.viewModel.inputs.applicationWillEnterForeground()
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    self.viewModel.inputs.applicationDidEnterBackground()
  }

  func application(_ application: UIApplication,
                   continue userActivity: NSUserActivity,
                   restorationHandler: @escaping ([Any]?) -> Void) -> Bool {

    return self.viewModel.inputs.applicationContinueUserActivity(userActivity)
  }

  func application(_ app: UIApplication, open url: URL,
                   options: [UIApplicationOpenURLOptionsKey: Any] = [:]) -> Bool {
    guard let sourceApplication = options[.sourceApplication] as? String else { return false }

    return self.viewModel.inputs.applicationOpenUrl(application: app,
                                                    url: url,
                                                    sourceApplication: sourceApplication,
                                                    annotation: options[.annotation] as Any)
  }

  func application(_ application: UIApplication,
                   open url: URL,
                   sourceApplication: String?,
                   annotation: Any) -> Bool {

    return self.viewModel.inputs.applicationOpenUrl(application: application,
                                                    url: url,
                                                    sourceApplication: sourceApplication,
                                                    annotation: annotation)
  }

  internal func application(_ application: UIApplication,
                            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    self.viewModel.inputs.didRegisterForRemoteNotifications(withDeviceTokenData: deviceToken)
  }

  internal func application(_ application: UIApplication,
                            didReceiveRemoteNotification userInfo: [AnyHashable: Any]) {

    self.viewModel.inputs.didReceive(remoteNotification: userInfo,
                                     applicationIsActive: application.applicationState == .active)
  }

  internal func application(_ application: UIApplication,
                            didReceive notification: UILocalNotification) {

    if let userInfo = notification.userInfo, userInfo["aps"] != nil {
      self.viewModel.inputs.didReceive(remoteNotification: userInfo,
                                       applicationIsActive: application.applicationState == .active)
    }
  }

  internal func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
    self.viewModel.inputs.applicationDidReceiveMemoryWarning()
  }

  internal func application(_ application: UIApplication,
                            performActionFor shortcutItem: UIApplicationShortcutItem,
                            completionHandler: @escaping (Bool) -> Void) {

    self.viewModel.inputs.applicationPerformActionForShortcutItem(shortcutItem)
    completionHandler(true)
  }

  fileprivate func presentContextualPermissionAlert(_ notification: Notification) {

    guard let context = notification.userInfo?.values.first as? PushNotificationDialog.Context else {
      return
    }

    let alert = UIAlertController(title: context.title, message: context.message, preferredStyle: .alert)

    alert.addAction(
      UIAlertAction(title: Strings.project_star_ok(), style: .default) { [weak self] _ in
        self?.viewModel.inputs.didAcceptReceivingRemoteNotifications()
      }
    )

    alert.addAction(
      UIAlertAction(title: PushNotificationDialog.titleForDismissal, style: .cancel, handler: { _ in
        PushNotificationDialog.didDenyAccess(for: context)
      })
    )

    DispatchQueue.main.async {
      if let viewController = notification.userInfo?[UserInfoKeys.viewController] as? UIViewController {
        viewController.present(alert, animated: true, completion: nil)
      } else {
        self.rootTabBarController?.present(alert, animated: true, completion: nil)
      }
    }
  }

  fileprivate func presentRemoteNotificationAlert(_ message: String) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)

    alert.addAction(
      UIAlertAction(title: Strings.View(), style: .default) { [weak self] _ in
        self?.viewModel.inputs.openRemoteNotificationTappedOk()
      }
    )

    alert.addAction(
      UIAlertAction(title: Strings.Dismiss(), style: .cancel, handler: nil)
    )

    DispatchQueue.main.async {
      self.rootTabBarController?.present(alert, animated: true, completion: nil)
    }
  }

  private func goToLiveStream(project: Project,
                              liveStreamEvent: LiveStreamEvent,
                              refTag: RefTag?) {

    let projectVc = ProjectPamphletViewController.configuredWith(projectOrParam: .left(project),
                                                                 refTag: refTag)

    let liveVc: UIViewController
    if liveStreamEvent.startDate < AppEnvironment.current.dateType.init().date {
      liveVc = LiveStreamContainerViewController.configuredWith(project: project,
                                                                liveStreamEvent: liveStreamEvent,
                                                                refTag: .push,
                                                                presentedFromProject: false)
    } else {
      liveVc = LiveStreamCountdownViewController.configuredWith(project: project,
                                                                liveStreamEvent: liveStreamEvent,
                                                                refTag: .push,
                                                                presentedFromProject: false)
    }

    let nav = UINavigationController(navigationBarClass: ClearNavigationBar.self, toolbarClass: nil)
    nav.viewControllers = [liveVc]

    self.rootTabBarController?.present(projectVc, animated: true) {
      projectVc.present(nav, animated: true)
    }
  }

  private func goToMessageThread(_ messageThread: MessageThread) {
    self.rootTabBarController?.switchToMessageThread(messageThread)
  }

  private func goToCreatorMessageThread(_ projectId: Param, _ messageThread: MessageThread) {
    self.rootTabBarController?
      .switchToCreatorMessageThread(projectId: projectId, messageThread: messageThread)
  }

  private func goToProjectActivities(_ projectId: Param) {
    self.rootTabBarController?.switchToProjectActivities(projectId: projectId)
  }

  private func findRedirectUrl(_ url: URL) {
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    let task = session.dataTask(with: url)
    task.resume()
  }
}

extension AppDelegate: BITHockeyManagerDelegate {
  func crashManagerDidFinishSendingCrashReport(_ crashManager: BITCrashManager!) {
    self.viewModel.inputs.crashManagerDidFinishSendingCrashReport()
  }
}

extension AppDelegate: URLSessionTaskDelegate {
  public func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest,
                         completionHandler: @escaping (URLRequest?) -> Void) {
    request.url.doIfSome(self.viewModel.inputs.foundRedirectUrl)
    completionHandler(nil)
  }
}
