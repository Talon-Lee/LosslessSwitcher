//
//  AppVersion.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 2/5/22.
//

import Foundation

let currentBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "22"
let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "2.1"
