// sdkcov functional checks: persistence and personal-data frameworks. Nothing here prompts the user: privacy-gated
// frameworks are checked up to their authorization state and the API that works without access (as on a fresh
// simulator); tests/apps/x86data covers a notification permission prompt.
import Foundation
import CoreData
import SwiftData
#if canImport(TabularData)
import TabularData
#endif
#if canImport(Contacts)
import Contacts
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(Photos)
import Photos
#endif
import UserNotifications
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

// What @Model expands to, written out: the Linux toolchain has no SwiftDataMacros plugin (Apple ships it for macOS
// only). Same shape as the macro's output: computed properties over the backing data, schemaMetadata, the
// init(backingData:) SwiftData calls, Observation through a registrar.
final class SDNote: PersistentModel {
    private var _$backingData: any SwiftData.BackingData<SDNote> = SDNote.createBackingData()
    private let _$observationRegistrar = Observation.ObservationRegistrar()
    var persistentBackingData: any SwiftData.BackingData<SDNote> { get { _$backingData } set { _$backingData = newValue } }
    static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        [.init(name: "title", keypath: \SDNote.title), .init(name: "stamp", keypath: \SDNote.stamp), .init(name: "tags", keypath: \SDNote.tags)]
    }
    required init(backingData: any SwiftData.BackingData<SDNote>) { _$backingData = backingData }
    init(title: String, stamp: Date = .now, tags: [String] = []) { self.title = title; self.stamp = stamp; self.tags = tags }
    var title: String {
        get { _$observationRegistrar.access(self, keyPath: \.title); return getValue(forKey: \.title) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.title) { setValue(forKey: \.title, to: newValue) } }
    }
    var stamp: Date {
        get { _$observationRegistrar.access(self, keyPath: \.stamp); return getValue(forKey: \.stamp) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.stamp) { setValue(forKey: \.stamp, to: newValue) } }
    }
    var tags: [String] {
        get { _$observationRegistrar.access(self, keyPath: \.tags); return getValue(forKey: \.tags) }
        set { _$observationRegistrar.withMutation(of: self, keyPath: \.tags) { setValue(forKey: \.tags, to: newValue) } }
    }
}
extension SDNote: Observation.Observable {}

extension Registry {
    static var data: [Check] {
        var c: [Check] = [
            check("CoreData", "sqlite-store-crud-migration") {
                let m = NSManagedObjectModel()
                let e = NSEntityDescription(); e.name = "Item"; e.managedObjectClassName = "NSManagedObject"
                let n = NSAttributeDescription(); n.name = "n"; n.attributeType = .integer64AttributeType
                let s = NSAttributeDescription(); s.name = "s"; s.attributeType = .stringAttributeType; s.isOptional = true
                e.properties = [n, s]; m.entities = [e]
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-\(UUID().uuidString).sqlite")
                defer { for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + x) } }
                let pc = NSPersistentContainer(name: "sdkcov", managedObjectModel: m)
                pc.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
                var err: Error?; pc.loadPersistentStores { _, e in err = e }
                if let err { throw Fail("load: \(err)") }
                let ctx = pc.newBackgroundContext()
                try await ctx.perform {
                    for i in 0..<500 { let o = NSManagedObject(entity: e, insertInto: ctx); o.setValue(i, forKey: "n"); o.setValue("item \(i)", forKey: "s") }
                    try ctx.save()
                }
                let r = NSFetchRequest<NSDictionary>(entityName: "Item"); r.resultType = .dictionaryResultType
                let sum = NSExpressionDescription(); sum.name = "t"; sum.expression = NSExpression(forFunction: "sum:", arguments: [NSExpression(forKeyPath: "n")]); sum.expressionResultType = .integer64AttributeType
                r.propertiesToFetch = [sum]
                let total = try pc.viewContext.fetch(r).first?["t"] as? Int
                try expect(total == 124750, "sum \(String(describing: total))")
                let del = NSBatchDeleteRequest(fetchRequest: NSFetchRequest(entityName: "Item")); del.resultType = .resultTypeCount
                let dn = (try pc.newBackgroundContext().execute(del) as? NSBatchDeleteResult)?.result as? Int
                try expect(dn == 500, "batch delete \(String(describing: dn))")
                return "500 rows, sum + batch delete"
            },
            check("SwiftData", "container-insert-fetch-predicate") {
                try await onMain {
                    // cloudKitDatabase .none: with the iCloud entitlement SwiftData would sync to CloudKit, which needs optional attributes
                    let cfg = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                    let mc = try ModelContainer(for: SDNote.self, configurations: cfg)
                    let ctx = mc.mainContext
                    for i in 0..<50 { ctx.insert(SDNote(title: "n\(i)", tags: i % 2 == 0 ? ["even"] : [])) }
                    try ctx.save()
                    // #Predicate { $0.title.starts(with: "n1") }, expanded (the Linux toolchain's Foundation macros name the
                    // open-source FoundationEssentials module)
                    let pred = Predicate<SDNote> { n in
                        PredicateExpressions.build_starts(PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(n), keyPath: \.title), with: PredicateExpressions.build_Arg("n1"))
                    }
                    let fd = FetchDescriptor<SDNote>(predicate: pred, sortBy: [SortDescriptor(\.title)])
                    let r = try ctx.fetch(fd)
                    try expect(r.count == 11, "fetched \(r.count)")
                    try expect(try ctx.fetchCount(FetchDescriptor<SDNote>()) == 50, "count")
                    return "ok"
                }
            },
            check("Foundation", "userdefaults-appgroup") {
                let d = UserDefaults.standard; d.set(["a": 1], forKey: "sdkcov"); try expect((d.dictionary(forKey: "sdkcov")?["a"] as? Int) == 1, "standard")
                guard let g = UserDefaults(suiteName: "group.com.x86sim.test.sdkcov") else { throw Fail("app group suite") }
                g.set("x", forKey: "k"); try expect(g.string(forKey: "k") == "x", "group defaults")
                let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.x86sim.test.sdkcov")
                try expect(u != nil, "app group container (entitlement com.apple.security.application-groups)")
                try Data("g".utf8).write(to: u!.appendingPathComponent("sdkcov.txt"))
                return u!.lastPathComponent
            },
            check("UserNotifications", "settings-schedule-pending") {
                let c = UNUserNotificationCenter.current()
                let st = await c.notificationSettings()
                let ct = UNMutableNotificationContent(); ct.badge = 1
                #if !os(tvOS)   // tvOS notifications carry a badge only
                c.setNotificationCategories([UNNotificationCategory(identifier: "sdkcov", actions: [UNNotificationAction(identifier: "ok", title: "OK")], intentIdentifiers: [])])
                ct.title = "sdkcov"; ct.categoryIdentifier = "sdkcov"
                #endif
                let req = UNNotificationRequest(identifier: "sdkcov-probe", content: ct, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false))
                do { try await c.add(req) } catch {
                    // without authorization iOS rejects the request (no prompt here: tests/apps/x86data answers one)
                    if st.authorizationStatus == .notDetermined || st.authorizationStatus == .denied { return "not authorized (\(st.authorizationStatus.rawValue)): add rejected as on iOS: \((error as NSError).code)" }
                    throw Fail("add: \(error) (authorization \(st.authorizationStatus.rawValue))")
                }
                let pend = await c.pendingNotificationRequests()
                c.removePendingNotificationRequests(withIdentifiers: ["sdkcov-probe"])
                try expect(pend.contains { $0.identifier == "sdkcov-probe" }, "pending \(pend.map(\.identifier))")
                #if !os(tvOS)
                let cats = await c.notificationCategories()
                try expect(cats.contains { $0.identifier == "sdkcov" }, "categories")
                #endif
                return "authorization \(st.authorizationStatus.rawValue)"
            },
        ]
        #if canImport(TabularData)
        c.append(check("TabularData", "csv-dataframe") {
            let csv = "name,score,team\nann,90,a\nbob,70,b\ncid,85,a\n"
            var df = try DataFrame(csvData: Data(csv.utf8))
            try expect(df.rows.count == 3 && df.columns.count == 3, "shape \(df.shape)")
            df.sort(on: "score", order: .descending)
            try expect(df.rows[0]["name"] as? String == "ann", "sort")
            let g = df.grouped(by: "team").sums("score", Int.self)
            try expect(g.rows.count == 2, "groups \(g.rows.count)")
            return "\(df.shape)"
        })
        #endif
        #if canImport(Contacts)
        c.append(check("Contacts", "authorization-vcard-formatter") {
            let st = CNContactStore.authorizationStatus(for: .contacts)
            let m = CNMutableContact(); m.givenName = "Ada"; m.familyName = "Lovelace"
            m.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 555 0100"))]
            let name = CNContactFormatter.string(from: m, style: .fullName)
            try expect(name == "Ada Lovelace", "formatter \(name ?? "nil")")
            let vc = try CNContactVCardSerialization.data(with: [m])
            let back = try CNContactVCardSerialization.contacts(with: vc)
            try expect(back.first?.familyName == "Lovelace", "vCard round trip")
            let pa = CNMutablePostalAddress(); pa.street = "1 Infinite Loop"; pa.city = "Cupertino"
            let pf = CNPostalAddressFormatter.string(from: pa, style: .mailingAddress)
            try expect(pf.contains("Cupertino"), "postal formatter gave \"\(pf)\"")
            if st == .authorized || st == .limited {
                let n = try CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: "a"), keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor]).count
                return "authorized, \(n) matches"
            }
            return "authorization \(st.rawValue), vCard \(vc.count) B"
        })
        #endif
        #if canImport(EventKit)
        c.append(check("EventKit", "authorization-event-recurrence") {
            let st = EKEventStore.authorizationStatus(for: .event)
            let store = EKEventStore()
            let e = EKEvent(eventStore: store); e.title = "sdkcov"; e.startDate = .now; e.endDate = .now.addingTimeInterval(3600)
            e.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 4)))
            try expect(e.hasRecurrenceRules, "recurrence")
            let r = EKReminder(eventStore: store); r.title = "sdkcov"
            return "authorization \(st.rawValue), \(store.sources.count) sources visible"
        })
        #endif
        #if canImport(Photos)
        c.append(check("Photos", "authorization") {
            let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if st == .authorized || st == .limited { return "authorized, \(PHAsset.fetchAssets(with: nil).count) assets" }
            return "authorization \(st.rawValue)"
        })
        #endif
        #if canImport(CoreSpotlight) && !os(tvOS)
        c.append(check("CoreSpotlight", "index-delete", timeout: 90) {   // first use: the index can take ~40 s, on Apple's simulator too
            try skipIf(!CSSearchableIndex.isIndexingAvailable(), "indexing unavailable")
            let a = CSSearchableItemAttributeSet(contentType: .text); a.title = "sdkcov probe"; a.contentDescription = "x86sim"
            let item = CSSearchableItem(uniqueIdentifier: "sdkcov-1", domainIdentifier: "sdkcov", attributeSet: a)
            try await CSSearchableIndex.default().indexSearchableItems([item])
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["sdkcov"])
            return "ok"
        })
        #endif
        #if canImport(CloudKit)
        c.append(check("CloudKit", "account-status", timeout: 40) {
            // a container from the iCloud entitlement; with no Apple ID signed in, Apple's simulator answers .noAccount
            let st: CKAccountStatus
            do { st = try await CKContainer(identifier: "iCloud.com.x86sim.test.sdkcov").accountStatus() }
            catch let e as CKError where e.code == .missingEntitlement {
                // simulated entitlements are not enough: CloudKit reads the application-identifier from a team signature
                throw Skip("CloudKit needs a team-signed application-identifier (Apple's simulator: same error)")
            }
            let rec = CKRecord(recordType: "Probe"); rec["n"] = 1
            try expect(rec["n"] as? Int == 1, "CKRecord")
            return "account status \(st.rawValue)"
        })
        c.append(check("Foundation", "ubiquitous-kvstore") {
            let kv = NSUbiquitousKeyValueStore.default; kv.set("x", forKey: "sdkcov")
            return "synchronize \(kv.synchronize()), ubiquity token \(FileManager.default.ubiquityIdentityToken == nil ? "none (no Apple ID)" : "present")"
        })
        #endif
        return c
    }
}
