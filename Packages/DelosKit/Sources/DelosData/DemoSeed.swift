#if DEBUG
import DelosHost
import Foundation

extension HostStore {
    /// DEBUG only: the demo harness (`DemoHarness`): a paired PC with no address (nothing is asked) and its apps, for screenshots.
    public func demoInstall(id: String, name: String, online: Bool, apps list: [HostApp], running: Int) {
        let xml = """
        <root status_code="200"><hostname>\(name)</hostname><uniqueid>\(id)</uniqueid><HttpsPort>47984</HttpsPort>\
        <appversion>7.1.431.-1</appversion><PairStatus>0</PairStatus><mac>AA:BB:CC:DD:EE:FF</mac><state>SUNSHINE_SERVER_FREE</state></root>
        """
        guard let info = try? ServerInfo.parse(Data(xml.utf8)) else { return }
        let reply = ServerInfoReply(info: info, address: HostAddress(host: "127.0.0.1", port: 1), source: .plainHTTP)
        var record = HostRecord(firstReply: reply).paired(with: HostPin(certificate: Data([1]), httpsPort: 47984))
        record.activeAddress = nil
        record.localAddress = nil
        record.runningAppID = running
        store(online ? record : record.markedOffline())
        apps[id] = list
    }
}
#endif
