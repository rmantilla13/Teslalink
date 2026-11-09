import Foundation

/// All logged data lives in one SQLite file on the device. No server, no Grafana.
///
/// High-volume rows (positions, charge samples) get real columns; summary rows (drives,
/// charges) keep indexed key columns plus a JSON payload so the schema can evolve freely.
public actor LogStore {
    private let db: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static let schemaVersion = 1

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try Self.migrate(db)
    }

    /// In-memory database for previews and tests.
    public static func inMemory() throws -> LogStore { try LogStore(path: ":memory:") }

    private static func migrate(_ db: SQLiteDatabase) throws {
        if db.userVersion < 1 {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS vehicles (vin TEXT PRIMARY KEY, json BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS drives (
                id INTEGER PRIMARY KEY AUTOINCREMENT, vin TEXT NOT NULL, start_date REAL NOT NULL, end_date REAL, json BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS drives_vin_start ON drives(vin, start_date);
            CREATE TABLE IF NOT EXISTS charges (
                id INTEGER PRIMARY KEY AUTOINCREMENT, vin TEXT NOT NULL, start_date REAL NOT NULL, end_date REAL, json BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS charges_vin_start ON charges(vin, start_date);
            CREATE TABLE IF NOT EXISTS positions (
                id INTEGER PRIMARY KEY AUTOINCREMENT, vin TEXT NOT NULL, drive_id INTEGER REFERENCES drives(id) ON DELETE CASCADE,
                date REAL NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, elevation REAL, speed REAL, power REAL,
                odometer REAL, soc INTEGER, rated_range REAL, outside_temp REAL, inside_temp REAL, source TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS positions_drive ON positions(drive_id, date);
            CREATE INDEX IF NOT EXISTS positions_vin_date ON positions(vin, date);
            CREATE TABLE IF NOT EXISTS charge_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL REFERENCES charges(id) ON DELETE CASCADE,
                date REAL NOT NULL, soc INTEGER, usable_soc INTEGER, rated_range REAL, ideal_range REAL, energy_added REAL,
                power REAL, voltage REAL, current REAL, phases INTEGER, outside_temp REAL, fast_type TEXT);
            CREATE INDEX IF NOT EXISTS samples_session ON charge_samples(session_id, date);
            CREATE TABLE IF NOT EXISTS states (
                id INTEGER PRIMARY KEY AUTOINCREMENT, vin TEXT NOT NULL, kind TEXT NOT NULL, start_date REAL NOT NULL, end_date REAL);
            CREATE INDEX IF NOT EXISTS states_vin_start ON states(vin, start_date);
            CREATE TABLE IF NOT EXISTS updates (
                id INTEGER PRIMARY KEY AUTOINCREMENT, vin TEXT NOT NULL, version TEXT NOT NULL, start_date REAL NOT NULL, end_date REAL);
            CREATE TABLE IF NOT EXISTS geofences (id INTEGER PRIMARY KEY AUTOINCREMENT, json BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, json BLOB NOT NULL);
            PRAGMA user_version = 1;
            """)
        }
    }

    // MARK: Vehicles

    public func upsert(_ v: Vehicle) throws {
        try db.run("INSERT INTO vehicles(vin, json) VALUES(?, ?) ON CONFLICT(vin) DO UPDATE SET json = excluded.json",
                   [.text(v.vin), .blob(try encoder.encode(v))])
    }

    public func vehicles() throws -> [Vehicle] {
        try db.query("SELECT json FROM vehicles ORDER BY vin").compactMap { try $0[0].data.map { try decoder.decode(Vehicle.self, from: $0) } }
    }

    public func vehicle(vin: String) throws -> Vehicle? {
        try db.query("SELECT json FROM vehicles WHERE vin = ?", [.text(vin)]).first?[0].data.map { try decoder.decode(Vehicle.self, from: $0) }
    }

    // MARK: Drives

    @discardableResult
    public func save(_ drive: Drive) throws -> Drive {
        var d = drive
        if let id = d.id {
            try db.run("UPDATE drives SET vin = ?, start_date = ?, end_date = ?, json = ? WHERE id = ?",
                       [.text(d.vin), SQLValue(d.startDate), SQLValue(d.endDate), .blob(try encoder.encode(d)), .int(id)])
        } else {
            let id = try db.run("INSERT INTO drives(vin, start_date, end_date, json) VALUES(?, ?, ?, ?)",
                                [.text(d.vin), SQLValue(d.startDate), SQLValue(d.endDate), .blob(Data("{}".utf8))])
            d.id = id
            try db.run("UPDATE drives SET json = ? WHERE id = ?", [.blob(try encoder.encode(d)), .int(id)])
        }
        return d
    }

    public func drives(vin: String, from: Date = .distantPast, to: Date = .distantFuture, limit: Int = 10_000) throws -> [Drive] {
        try db.query("SELECT json FROM drives WHERE vin = ? AND start_date >= ? AND start_date < ? ORDER BY start_date DESC LIMIT ?",
                     [.text(vin), SQLValue(from), SQLValue(to), .int(Int64(limit))])
            .compactMap { try $0[0].data.map { try decoder.decode(Drive.self, from: $0) } }
    }

    public func drive(id: RecordID) throws -> Drive? {
        try db.query("SELECT json FROM drives WHERE id = ?", [.int(id)]).first?[0].data.map { try decoder.decode(Drive.self, from: $0) }
    }

    public func openDrive(vin: String) throws -> Drive? {
        try db.query("SELECT json FROM drives WHERE vin = ? AND end_date IS NULL ORDER BY start_date DESC LIMIT 1", [.text(vin)])
            .first?[0].data.map { try decoder.decode(Drive.self, from: $0) }
    }

    /// Closed drives with coordinates but no street address yet (newest first).
    public func drivesMissingAddresses(limit: Int = 20) throws -> [Drive] {
        let rows = try db.query("SELECT json FROM drives WHERE end_date IS NOT NULL ORDER BY start_date DESC LIMIT 500")
        let drives: [Drive] = try rows.compactMap { row in try row[0].data.map { try decoder.decode(Drive.self, from: $0) } }
        let missing = drives.filter { d in
            let start = d.startAddress == nil && d.startLatitude != nil
            let end = d.endAddress == nil && d.endLatitude != nil
            return start || end
        }
        return Array(missing.prefix(limit))
    }

    public func chargesMissingAddresses(limit: Int = 20) throws -> [ChargeSession] {
        let rows = try db.query("SELECT json FROM charges ORDER BY start_date DESC LIMIT 500")
        let charges: [ChargeSession] = try rows.compactMap { row in try row[0].data.map { try decoder.decode(ChargeSession.self, from: $0) } }
        return Array(charges.filter { $0.address == nil && $0.latitude != nil }.prefix(limit))
    }

    public func deleteDrive(id: RecordID) throws {
        try db.run("DELETE FROM drives WHERE id = ?", [.int(id)])
    }

    // MARK: Positions

    public func insert(_ p: Position) throws {
        try db.run("""
            INSERT INTO positions(vin, drive_id, date, lat, lon, elevation, speed, power, odometer, soc, rated_range, outside_temp, inside_temp, source)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(p.vin), SQLValue(p.driveID), SQLValue(p.timestamp), .double(p.latitude), .double(p.longitude),
                  SQLValue(p.elevationM), SQLValue(p.speedKmh), SQLValue(p.powerKw), SQLValue(p.odometerKm),
                  SQLValue(p.batteryLevel), SQLValue(p.ratedRangeKm), SQLValue(p.outsideTempC), SQLValue(p.insideTempC),
                  .text(p.source.rawValue)])
    }

    public func insert(_ positions: [Position]) throws {
        try db.transaction { for p in positions { try insert(p) } }
    }

    public func positions(driveID: RecordID) throws -> [Position] {
        try db.query("SELECT * FROM positions WHERE drive_id = ? ORDER BY date", [.int(driveID)]).map(Self.position)
    }

    public func positions(vin: String, from: Date, to: Date) throws -> [Position] {
        try db.query("SELECT * FROM positions WHERE vin = ? AND date >= ? AND date < ? ORDER BY date",
                     [.text(vin), SQLValue(from), SQLValue(to)]).map(Self.position)
    }

    /// Links unassigned phone GPS points in a time window to a drive.
    public func attachPhonePositions(vin: String, driveID: RecordID, from: Date, to: Date) throws {
        try db.run("UPDATE positions SET drive_id = ? WHERE vin = ? AND source = 'phone' AND drive_id IS NULL AND date >= ? AND date <= ?",
                   [.int(driveID), .text(vin), SQLValue(from), SQLValue(to)])
    }

    public func detachPhonePositions(driveID: RecordID) throws {
        try db.run("UPDATE positions SET drive_id = NULL WHERE drive_id = ? AND source = 'phone'", [.int(driveID)])
    }

    /// Phone GPS that never matched a drive (you were in another car, on a bus...) is deleted.
    public func pruneOrphanPhonePositions(olderThan date: Date) throws {
        try db.run("DELETE FROM positions WHERE source = 'phone' AND drive_id IS NULL AND date < ?", [SQLValue(date)])
    }

    public func lastPosition(vin: String) throws -> Position? {
        try db.query("SELECT * FROM positions WHERE vin = ? ORDER BY date DESC LIMIT 1", [.text(vin)]).first.map(Self.position)
    }

    private static func position(_ r: [SQLValue]) -> Position {
        Position(id: r[0].int64, vin: r[1].string ?? "", driveID: r[2].int64, timestamp: r[3].date ?? .distantPast,
                 latitude: r[4].double ?? 0, longitude: r[5].double ?? 0, elevationM: r[6].double, speedKmh: r[7].double,
                 powerKw: r[8].double, odometerKm: r[9].double, batteryLevel: r[10].int, ratedRangeKm: r[11].double,
                 outsideTempC: r[12].double, insideTempC: r[13].double,
                 source: PositionSource(rawValue: r[14].string ?? "") ?? .vehicle)
    }

    // MARK: Charges

    @discardableResult
    public func save(_ charge: ChargeSession) throws -> ChargeSession {
        var c = charge
        if let id = c.id {
            try db.run("UPDATE charges SET vin = ?, start_date = ?, end_date = ?, json = ? WHERE id = ?",
                       [.text(c.vin), SQLValue(c.startDate), SQLValue(c.endDate), .blob(try encoder.encode(c)), .int(id)])
        } else {
            let id = try db.run("INSERT INTO charges(vin, start_date, end_date, json) VALUES(?, ?, ?, ?)",
                                [.text(c.vin), SQLValue(c.startDate), SQLValue(c.endDate), .blob(Data("{}".utf8))])
            c.id = id
            try db.run("UPDATE charges SET json = ? WHERE id = ?", [.blob(try encoder.encode(c)), .int(id)])
        }
        return c
    }

    public func charges(vin: String, from: Date = .distantPast, to: Date = .distantFuture, limit: Int = 10_000) throws -> [ChargeSession] {
        try db.query("SELECT json FROM charges WHERE vin = ? AND start_date >= ? AND start_date < ? ORDER BY start_date DESC LIMIT ?",
                     [.text(vin), SQLValue(from), SQLValue(to), .int(Int64(limit))])
            .compactMap { try $0[0].data.map { try decoder.decode(ChargeSession.self, from: $0) } }
    }

    public func charge(id: RecordID) throws -> ChargeSession? {
        try db.query("SELECT json FROM charges WHERE id = ?", [.int(id)]).first?[0].data.map { try decoder.decode(ChargeSession.self, from: $0) }
    }

    public func openCharge(vin: String) throws -> ChargeSession? {
        try db.query("SELECT json FROM charges WHERE vin = ? AND end_date IS NULL ORDER BY start_date DESC LIMIT 1", [.text(vin)])
            .first?[0].data.map { try decoder.decode(ChargeSession.self, from: $0) }
    }

    public func deleteCharge(id: RecordID) throws {
        try db.run("DELETE FROM charges WHERE id = ?", [.int(id)])
    }

    public func insert(_ s: ChargeSample) throws {
        try db.run("""
            INSERT INTO charge_samples(session_id, date, soc, usable_soc, rated_range, ideal_range, energy_added, power, voltage, current, phases, outside_temp, fast_type)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.int(s.sessionID), SQLValue(s.timestamp), SQLValue(s.batteryLevel), SQLValue(s.usableBatteryLevel),
                  SQLValue(s.ratedRangeKm), SQLValue(s.idealRangeKm), SQLValue(s.chargeEnergyAddedKwh), SQLValue(s.chargerPowerKw),
                  SQLValue(s.chargerVoltage), SQLValue(s.chargerActualCurrent), SQLValue(s.chargerPhases), SQLValue(s.outsideTempC),
                  SQLValue(s.fastChargerType)])
    }

    public func samples(sessionID: RecordID) throws -> [ChargeSample] {
        try db.query("SELECT * FROM charge_samples WHERE session_id = ? ORDER BY date", [.int(sessionID)]).map { r in
            ChargeSample(id: r[0].int64, sessionID: r[1].int64 ?? 0, timestamp: r[2].date ?? .distantPast, batteryLevel: r[3].int,
                         usableBatteryLevel: r[4].int, ratedRangeKm: r[5].double, idealRangeKm: r[6].double,
                         chargeEnergyAddedKwh: r[7].double, chargerPowerKw: r[8].double, chargerVoltage: r[9].double,
                         chargerActualCurrent: r[10].double, chargerPhases: r[11].int, outsideTempC: r[12].double,
                         fastChargerType: r[13].string)
        }
    }

    // MARK: States & updates

    public func beginState(_ kind: StateRecord.Kind, vin: String, at date: Date) throws {
        try db.transaction {
            try db.run("UPDATE states SET end_date = ? WHERE vin = ? AND end_date IS NULL", [SQLValue(date), .text(vin)])
            try db.run("INSERT INTO states(vin, kind, start_date) VALUES(?, ?, ?)", [.text(vin), .text(kind.rawValue), SQLValue(date)])
        }
    }

    public func states(vin: String, from: Date = .distantPast, to: Date = .distantFuture) throws -> [StateRecord] {
        try db.query("SELECT id, vin, kind, start_date, end_date FROM states WHERE vin = ? AND (end_date IS NULL OR end_date >= ?) AND start_date < ? ORDER BY start_date",
                     [.text(vin), SQLValue(from), SQLValue(to)]).map { r in
            StateRecord(id: r[0].int64, vin: r[1].string ?? "", kind: StateRecord.Kind(rawValue: r[2].string ?? "") ?? .online,
                        startDate: r[3].date ?? .distantPast, endDate: r[4].date)
        }
    }

    public func beginUpdate(vin: String, version: String, at date: Date) throws {
        try db.run("INSERT INTO updates(vin, version, start_date) VALUES(?, ?, ?)", [.text(vin), .text(version), SQLValue(date)])
    }

    public func finishUpdate(vin: String, at date: Date) throws {
        try db.run("UPDATE updates SET end_date = ? WHERE vin = ? AND end_date IS NULL", [SQLValue(date), .text(vin)])
    }

    public func updates(vin: String) throws -> [SoftwareUpdate] {
        try db.query("SELECT id, vin, version, start_date, end_date FROM updates WHERE vin = ? ORDER BY start_date DESC", [.text(vin)]).map { r in
            SoftwareUpdate(id: r[0].int64, vin: r[1].string ?? "", version: r[2].string ?? "", startDate: r[3].date ?? .distantPast, endDate: r[4].date)
        }
    }

    // MARK: Geofences

    @discardableResult
    public func save(_ fence: Geofence) throws -> Geofence {
        var g = fence
        if let id = g.id {
            try db.run("UPDATE geofences SET json = ? WHERE id = ?", [.blob(try encoder.encode(g)), .int(id)])
        } else {
            let id = try db.run("INSERT INTO geofences(json) VALUES('{}')")
            g.id = id
            try db.run("UPDATE geofences SET json = ? WHERE id = ?", [.blob(try encoder.encode(g)), .int(id)])
        }
        return g
    }

    public func geofences() throws -> [Geofence] {
        try db.query("SELECT json FROM geofences ORDER BY id").compactMap { try $0[0].data.map { try decoder.decode(Geofence.self, from: $0) } }
    }

    public func deleteGeofence(id: RecordID) throws {
        try db.run("DELETE FROM geofences WHERE id = ?", [.int(id)])
    }

    // MARK: Key-value (logger checkpoints, settings)

    public func set<T: Encodable>(_ value: T?, for key: String) throws {
        if let value {
            try db.run("INSERT INTO kv(key, json) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET json = excluded.json",
                       [.text(key), .blob(try encoder.encode(value))])
        } else {
            try db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    public func get<T: Decodable>(_ type: T.Type, for key: String) throws -> T? {
        try db.query("SELECT json FROM kv WHERE key = ?", [.text(key)]).first?[0].data.map { try decoder.decode(T.self, from: $0) }
    }

    // MARK: Export

    /// Exports every table as JSON for backup / moving to a new phone.
    public func exportJSON() throws -> Data {
        struct Export: Encodable {
            var vehicles: [Vehicle]; var drives: [Drive]; var charges: [ChargeSession]; var geofences: [Geofence]
        }
        let vs = try vehicles()
        let e = Export(vehicles: vs,
                       drives: try vs.flatMap { try drives(vin: $0.vin) },
                       charges: try vs.flatMap { try charges(vin: $0.vin) },
                       geofences: try geofences())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(e)
    }
}
