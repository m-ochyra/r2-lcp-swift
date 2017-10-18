//
//  LcpUtils.swift
//  readium-lcp-swift
//
//  Created by Alexandre Camilleri on 9/14/17.
//  Copyright © 2017 Readium. All rights reserved.
//

import Foundation
import PromiseKit
import ZIPFoundation
import R2Shared

public class LcpUtils {
    public init () {}

    ///
    ///
    /// - Parameters:
    ///   - drm: The partialy completed DRM.
    ///   - url: The epub archive url.
    ///   - providedPassphrase: The passphrase, if not provided will look in base to find it.
    ///   - completion: The code to be exected on success.
    public func resolve(drm: Drm,
                        forLicenseOf url: URL,
                        providedPassphrase: String?,
                        completion: @escaping (Drm, Error?, String?) -> Void)
    {
        let lcp: Lcp

        do {
            lcp = try Lcp.init(withLicenseDocumentIn: url)
        } catch {
            completion(drm, error, nil)
            return
        }

        // 1/ Validate the license structure
        // --- Cyril block.

        firstly {
            // If a passphrase has been provided.
            if let providedPassphrase = providedPassphrase {
                return  self.checkPassphrase(providedPassphrase)
            } else {
                // 2/ Try to get the passphrase associated with the license in DB.
                return try self.checkDbPassphrases(lcp)
            }
            }.then { passphrase in // Passphrase is valid from here.
                //4/ Store the passphrase hash + license id tuple securely.
                self.storePassphrase(passphrase,
                                     lcp.license.id,
                                     lcp.license.provider)
            }.then {
                completion(drm, nil, nil)
            }.catch { error in
                completion(drm, error, lcp.license.getHint())
        }

    }

    /// <#Description#>
    ///
    /// - Parameter passphrase: <#passphrase description#>
    /// - Returns: <#return value description#>
    private func checkPassphrase(_ passphrase: String) -> Promise<String> {
        return Promise<String> { fulfill, reject in
            // CYRILCODE - to check provided passphrase
            //if fail, reject/throw
            fulfill(passphrase)
        }
    }

    /// <#Description#>
    ///
    /// - Parameters:
    ///   - lcp: <#lcp description#>
    ///   - passphrasePrompter: <#passphrasePrompter description#>
    /// - Returns: <#return value description#>
    private func checkDbPassphrases(_ lcp: Lcp) throws -> Promise<String> {
        /// 2.1/ Check if a passphrase hash has already been stored for the license.
        /// 2.2/ Check if one or more passphrase hash associated with licenses
        ///      from the same provider have been stored.
        var passphrases = [String]()
        let db = LCPDatabase.shared
        passphrases = (try? db.transactions.possiblePassphrases(for: lcp.license.id,
                                                                and: lcp.license.provider)) ?? []

        guard !passphrases.isEmpty else {
            throw LcpError.passphraseNeeded
        }
        print(passphrases.description)
        /// CYRILCODE - check if any of the passphrases match
        // if yes fulfill() with it. // return
        // lcp.license.encryption.userKey.keyCheck
        return checkPassphrase("passphrase")
    }

    /// <#Description#>
    ///
    /// - Parameters:
    ///   - passphrase: <#passphrase description#>
    ///   - licenseId: <#licenseId description#>
    ///   - provider: <#provider description#>
    /// - Returns: <#return value description#>
    private func storePassphrase(_ passphrase: String, _ licenseId: String, _ provider: URL) -> Promise<Void> {
        return Promise { fulfill, reject in
            let db = LCPDatabase.shared

            do {
                try db.transactions.add(licenseId, provider.absoluteString, passphrase)
            } catch {
                reject(error)
            }
            fulfill()
        }
    }

    /// Process a LCP License Document (LCPL).
    /// Fetching Status Document, updating License Document, Fetching Publication,
    /// and moving the (updated) License Document into the publication archive.
    ///
    /// - Parameters:
    ///   - path: The path of the License Document (LCPL).
    ///   - completion: The handler to be called on completion.
    public func publication(forLicenseAt url: URL, completion: @escaping (URL?, Error?) -> Void) {
        let lcp: Lcp

        do {
            lcp = try Lcp.init(withLicenseDocumentAt: url)
        } catch {
            completion(nil, error)
            return
        }

        // CYRILCODE -  check for valid license.

        firstly {
            /// 3.1/ Fetch the status document.
            /// 3.2/ Validate the status document.
            return lcp.fetchStatusDocument()
            }.then { _ -> Promise<Void> in
                /// 3.3/ Check that the status is "ready" or "active".
                guard lcp.status?.status == StatusDocument.Status.ready
                    || lcp.status?.status == StatusDocument.Status.active else {
                        /// If this is not the case (revoked, returned, cancelled,
                        /// expired), the app will notify the user and stop there.
                        throw LcpError.licenseStatus
                }
                /// 3.4/ Check if the license has been updated. If it is the case,
                //       the app must:
                /// 3.4.1/ Fetch the updated license.
                /// 3.4.2/ Validate the updated license. If the updated license 
                ///        is not valid, the app must keep the current one.
                /// 3.4.3/ Replace the current license by the updated one in the
                ///        EPUB archive.
                return lcp.updateLicenseDocument()
            }.then { _ -> Promise<URL> in
                /// 4/ Check the rights.
                guard lcp.areRightsValid() else {
                    throw LcpError.invalidRights
                }
                /// 5/ Register the device / license if needed.
                lcp.register()
                /// 6/ Fetch the publication.
                return lcp.fetchPublication()
            }.then { publicationUrl -> Void in
                /// Move the license document in the publication.
                try self.moveLicense(from: lcp.licensePath, to: publicationUrl)
                completion(publicationUrl, nil)
            }.catch { error in
                completion(nil, error)
        }
    }

    /// Moves the license.lcpl file from the Documents/Inbox/ to the Zip archive
    /// META-INF folder.
    ///
    /// - Parameters:
    ///   - licenseUrl: The url of the license.lcpl file on the file system.
    ///   - publicationUrl: The url of the publication archive
    /// - Throws: ``.
    internal func moveLicense(from licenseUrl: URL, to publicationUrl: URL) throws {
        guard let archive = Archive(url: publicationUrl, accessMode: .update) else  {
            throw LcpError.archive
        }
        // Create local META-INF folder to respect the zip file hierachy.
        let fileManager = FileManager.default
        var urlMetaInf = licenseUrl.deletingLastPathComponent()

        urlMetaInf.appendPathComponent("META-INF", isDirectory: true)
        try fileManager.createDirectory(at: urlMetaInf, withIntermediateDirectories: true, attributes: nil)

        // Move license in the META-INF local folder.
        try fileManager.moveItem(at: licenseUrl, to: urlMetaInf.appendingPathComponent("license.lcpl"))
        // Copy META-INF/license.lcpl to archive.
        try archive.addEntry(with: urlMetaInf.lastPathComponent.appending("/license.lcpl"),
                             relativeTo: urlMetaInf.deletingLastPathComponent())
        // Delete META-INF/license.lcpl from inbox.
        try fileManager.removeItem(at: urlMetaInf)
    }
}











