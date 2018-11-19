//
//  AppDelegate.swift
//  GlidARRnD
//
//  Created by apple on 05/11/18.
//  Copyright © 2018 Appinvenitv Technologies. All rights reserved.
//

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    var window: UIWindow?
    @objc static let shared = UIApplication.shared.delegate as! AppDelegate
    @objc var glResourceHandler: SampleGLResourceHandler?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }


    func applicationDidEnterBackground(_ application: UIApplication) {
        if self.glResourceHandler != nil {
            // Delete OpenGL resources (e.g. framebuffer) of the SampleApp AR View
            self.glResourceHandler?.freeOpenGLESResources()
            self.glResourceHandler?.finishOpenGLESCommands()
        }
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
                
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown

    }


}

