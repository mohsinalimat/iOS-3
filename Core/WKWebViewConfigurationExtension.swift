//
//  WKWebViewConfigurationExtension.swift
//  DuckDuckGo
//
//  Copyright © 2017 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//


import WebKit

extension WKWebViewConfiguration {
    
    struct WebStoreCacheKeys {
        static let disconnect = "disconnect"
        static let easylist = "easylist"
        static let easyprivacy = "easyprivacy"
    }

    public static func persistent() -> WKWebViewConfiguration {
        return configuration(persistsData: true)
    }
    
    public static func nonPersistent() -> WKWebViewConfiguration {
        return configuration(persistsData: false)
    }
    
    private static func configuration(persistsData: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if !persistsData {
            configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }
        if #available(iOSApplicationExtension 10.0, *) {
            configuration.dataDetectorTypes = [.link, .phoneNumber]
        }
        configuration.loadScripts()
        return configuration
    }
    
    public func loadScripts() {
        loadDocumentLevelScripts()
        
        if #available(iOS 11.0, *) {
            loadSiteMonitoringScripts()
        } else {
            loadLegacySiteMonitoringScripts()
        }
    }
    
    private func loadDocumentLevelScripts() {
        load(scripts: [ .document, .favicon ] )
    }
   
    @available(iOSApplicationExtension 11.0, *)
    private func loadSiteMonitoringScripts() {
        load(scripts: [ .beforeLoadNotification ], forMainFrameOnly: false)
        loadContentBlockerRules()
    }
    
    @available(iOSApplicationExtension 11.0, *)
    private func loadContentBlockerRules() {
        
        let configuration = ContentBlockerConfigurationUserDefaults()
        let bundle = Bundle(for: BundleFinder.self)
        let fileLoader = FileLoader()
        
        if !configuration.enabled {
            userContentController.removeAllContentRuleLists()
            return
        }
        
        loadCachedRulelist(identifier: WebStoreCacheKeys.disconnect) { () -> String? in
            return DisconnectMeStore().appleRulesJson
        }
        
        
        loadCachedRulelist(identifier: WebStoreCacheKeys.easylist) { () -> String? in
            return try? fileLoader.loadString(fileName: "easylist.json", fromBundle: bundle)
        }
        
        loadCachedRulelist(identifier: WebStoreCacheKeys.easyprivacy) { () -> String? in
            return try? fileLoader.loadString(fileName: "easyprivacy.json", fromBundle: bundle)
        }
   
    }
    
    @available(iOSApplicationExtension 11.0, *)
    private func loadCachedRulelist(identifier: String, fallbackDataProvider: @escaping () -> String?) {
        let ruleStore = WKContentRuleListStore.default()!
        ruleStore.lookUpContentRuleList(forIdentifier: identifier) {  list, error in
            
            if let list = list {
                self.userContentController.add(list)
                return
            }
            
            guard let rules = fallbackDataProvider() else {
                Logger.log(items: "\(identifier) webkit block list did not load")
                return
            }
            
            ruleStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, error in
                guard let list = list, error == nil else {
                    Logger.log(items: "\(identifier) webkit block list did not compile", error ?? "")
                    return
                }
                self.userContentController.add(list)
            }
        }
    }
    
    public static func removeDisconnectRulesFromCache() {
        if #available(iOS 11.0, *) {
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: WebStoreCacheKeys.disconnect) { _ in }
        }
    }
    
    private func loadLegacySiteMonitoringScripts() {
        let configuration = ContentBlockerConfigurationUserDefaults()
        let whitelist = configuration.domainWhitelist.toJsonLookupString()
        loadLegacyContentBlockerDependencyScripts()
        loadLegacyBlockerData(with: whitelist, and:  configuration.enabled)
        load(scripts: [ .disconnectme, .contentblocker ], forMainFrameOnly: false)
    }
    
    private func loadLegacyContentBlockerDependencyScripts() {

        if #available(iOS 10, *) {
            load(scripts: [ .messaging, .apbfilter, .tlds ], forMainFrameOnly: false)
        } else {
            load(scripts: [ .messaging, .apbfilterES2015, .tlds ], forMainFrameOnly: false)
        }
    }
    
    private func loadLegacyBlockerData(with whitelist: String, and blockingEnabled: Bool) {
        let easylistStore = EasylistStore()
        let disconnectMeStore = DisconnectMeStore()
        let javascriptLoader = JavascriptLoader()
        
        javascriptLoader.load(script: .blockerData, withReplacements: [
            "${blocking_enabled}": "\(blockingEnabled)",
            "${disconnectmeBanned}": disconnectMeStore.bannedTrackersJson,
            "${disconnectmeAllowed}": disconnectMeStore.allowedTrackersJson,
            "${whitelist}": whitelist ],
                              andController:userContentController,
                              forMainFrameOnly: false)
        
        let cache = ContentBlockerStringCache()
        if let cachedEasylist = cache.get(named: EasylistStore.CacheNames.easylist), let cachedEasylistPrivacy = cache.get(named: EasylistStore.CacheNames.easylistPrivacy) {
            
            Logger.log(text: "using cached easylist")

            if #available(iOS 10, *) {
                javascriptLoader.load(.bloom, withController: userContentController, forMainFrameOnly: false)
            } else {
                javascriptLoader.load(.bloomES2015, withController: userContentController, forMainFrameOnly: false)
            }
            
            javascriptLoader.load(script: .cachedEasylist, withReplacements: [
                "${easylist_privacy_json}": cachedEasylistPrivacy,
                "${easylist_general_json}": cachedEasylist ],
                                  andController: userContentController,
                                  forMainFrameOnly: false)
            
        } else if let easylist = easylistStore.easylist,
            let easylistPrivacy = easylistStore.easylistPrivacy {
            
            Logger.log(text: "parsing easylist")

            javascriptLoader.load(script: .easylistParsing, withReplacements: [
                "${easylist_privacy}": easylistPrivacy,
                "${easylist_general}": easylist ],
                                  andController: userContentController,
                                  forMainFrameOnly: false)
            
        }
        
    }
    
    private func load(scripts: [JavascriptLoader.Script], forMainFrameOnly: Bool = true) {
        let javascriptLoader = JavascriptLoader()
        for script in scripts {
            javascriptLoader.load(script, withController: userContentController, forMainFrameOnly: forMainFrameOnly)
        }
    }
}

fileprivate extension Set where Element == String {
    
    func toJsonLookupString() -> String {
        return reduce("{", { (result, next) -> String in
            let separator = result != "{" ? ", " : ""
            return "\(result)\(separator) \"\(next)\" : true"
        }).appending("}")
    }
}

private class BundleFinder {}
