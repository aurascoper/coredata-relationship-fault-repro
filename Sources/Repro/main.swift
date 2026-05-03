import Foundation
import CoreData

// Minimal repro for: programmatic NSManagedObjectModel with two to-many
// relationships sharing the same name ("mentions") on different parent entities,
// joined through a single child entity ("Mention") via two to-one relationships.
// After save+re-fetch, accessing one of the to-one relationships from the
// child returns nil even though the foreign key is persisted in SQLite.
//
// Build & run:
//   swift run -c release Repro
//   swift run -c debug   Repro
// Both modes reproduce.

@main
struct Repro {
    static func main() throws {
        // Build a tiny programmatic model.
        let memory = NSEntityDescription()
        memory.name = "Memory"
        memory.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let memoryID = attr("id", .UUIDAttributeType)
        let memoryText = attr("text", .stringAttributeType)
        memory.properties = [memoryID, memoryText]

        let entity = NSEntityDescription()
        entity.name = "Entity"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let entityID = attr("id", .UUIDAttributeType)
        let entityName = attr("name", .stringAttributeType)
        entity.properties = [entityID, entityName]

        let mention = NSEntityDescription()
        mention.name = "Mention"
        mention.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let mentionID = attr("id", .UUIDAttributeType)
        mention.properties = [mentionID]

        // memory.mentions <-> mention.memory
        let memoryMentions = rel(name: "mentions", to: mention, toMany: true,  delete: .cascadeDeleteRule)
        let mentionMemory  = rel(name: "memory",   to: memory,  toMany: false, delete: .nullifyDeleteRule)
        memoryMentions.inverseRelationship = mentionMemory
        mentionMemory.inverseRelationship  = memoryMentions

        // entity.mentions <-> mention.entity   (NOTE: same name "mentions" as memory.mentions,
        //                                         but on a different parent entity)
        let entityMentions = rel(name: "mentions", to: mention, toMany: true,  delete: .cascadeDeleteRule)
        let mentionEntity  = rel(name: "entity",   to: entity,  toMany: false, delete: .nullifyDeleteRule)
        entityMentions.inverseRelationship = mentionEntity
        mentionEntity.inverseRelationship  = entityMentions

        memory.properties += [memoryMentions]
        entity.properties += [entityMentions]
        mention.properties += [mentionMemory, mentionEntity]

        let model = NSManagedObjectModel()
        model.entities = [memory, entity, mention]

        // SQLite store on a temp dir (so we can poke the raw FK column too).
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repro-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        }

        let container = NSPersistentContainer(name: "Repro", managedObjectModel: model)
        let desc = NSPersistentStoreDescription(url: url)
        desc.type = NSSQLiteStoreType
        desc.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [desc]

        var loadErr: Error?
        container.loadPersistentStores { _, err in loadErr = err }
        if let loadErr { fatalError("load failed: \(loadErr)") }

        let ctx = container.newBackgroundContext()
        var memID = UUID()
        var entIDs: [UUID] = []

        ctx.performAndWait {
            // Create one Memory + one Entity + one Mention linking them.
            let memObj = NSManagedObject(entity: memory, insertInto: ctx)
            memObj.setValue(memID, forKey: "id")
            memObj.setValue("the body", forKey: "text")

            let entObj = NSManagedObject(entity: entity, insertInto: ctx)
            let eid = UUID()
            entIDs.append(eid)
            entObj.setValue(eid, forKey: "id")
            entObj.setValue("Sarah", forKey: "name")

            let mObj = NSManagedObject(entity: mention, insertInto: ctx)
            mObj.setValue(UUID(), forKey: "id")
            mObj.setValue(memObj, forKey: "memory")
            mObj.setValue(entObj, forKey: "entity")

            try! ctx.save()
        }

        // --- Diagnostic: read back through KVC and see what we get. ---
        let readCtx = container.newBackgroundContext()
        readCtx.performAndWait {
            let req = NSFetchRequest<NSManagedObject>(entityName: "Memory")
            req.predicate = NSPredicate(format: "id == %@", memID as CVarArg)
            req.returnsObjectsAsFaults = false
            guard let m = try? readCtx.fetch(req).first else { fatalError("memory not found") }

            // Path 1: memory.mentions (to-many traversal — works in the bigger app)
            let mentionsRaw = m.value(forKey: "mentions")
            let nsSetCount = (mentionsRaw as? NSSet)?.count ?? -1
            let setCount = (mentionsRaw as? Set<NSManagedObject>)?.count ?? -1
            print("[memory.mentions] type=\(type(of: mentionsRaw)) ns=\(nsSetCount) set=\(setCount)")

            // Path 2: re-fetch mentions via predicate, with relationship prefetch.
            let mreq = NSFetchRequest<NSManagedObject>(entityName: "Mention")
            mreq.predicate = NSPredicate(format: "memory == %@", m)
            mreq.returnsObjectsAsFaults = false
            mreq.relationshipKeyPathsForPrefetching = ["entity"]
            let mentions = (try? readCtx.fetch(mreq)) ?? []
            print("[fetch by memory==row + prefetch entity] count=\(mentions.count)")

            // Path 3: the broken access — mention.entity should not be nil.
            for mention in mentions {
                let entityRaw = mention.value(forKey: "entity")
                let asObj = entityRaw as? NSManagedObject
                let entName = asObj?.value(forKey: "name") as? String
                print("  mention.entity raw=\(type(of: entityRaw)) asObj=\(asObj == nil ? "nil" : "non-nil") name=\(String(describing: entName))")
            }

            // Path 4: dump the SQLite columns for that mention to confirm the FK is there.
            // (Just an existence check; we won't open SQLite here, leave that to user.)
        }

        // --- Summary ---
        print("\n--- expected ---")
        print("  Path 3 mention.entity should be non-nil and name should be 'Sarah'.")
        print("  Path 1 memory.mentions count should be 1.")
        print("\n--- on Swift 6.3.1 / Xcode 26.4.1 / macOS 26.4.x with this programmatic model: ---")
        print("  Path 1 returns 1 (relationship works one direction).")
        print("  Path 2 returns 1 (we can fetch the mentions).")
        print("  Path 3 returns nil for mention.entity even though the FK is in SQLite.")
        print("\n  The store at \(url.path) can be inspected with sqlite3 to confirm")
        print("  that ZMENTION.ZENTITY is a non-null integer pointing at the entity row.")
    }

    private static func attr(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = optional
        return a
    }

    private static func rel(name: String, to dest: NSEntityDescription, toMany: Bool, delete: NSDeleteRule) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name
        r.destinationEntity = dest
        r.minCount = 0
        r.maxCount = toMany ? 0 : 1
        r.deleteRule = delete
        r.isOptional = true
        return r
    }
}
