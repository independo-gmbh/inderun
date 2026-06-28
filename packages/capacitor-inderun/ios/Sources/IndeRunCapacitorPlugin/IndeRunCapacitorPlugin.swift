#if canImport(Capacitor)
import Capacitor
import Foundation
import IndeRunCore

@objc(IndeRunCapacitorPlugin)
public final class IndeRunCapacitorPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "IndeRunCapacitorPlugin"
    public let jsName = "IndeRunCapacitor"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "configure", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "run", returnType: CAPPluginReturnPromise)
    ]

    private let implementation = IndeRunCapacitorBridge()

    @objc func configure(_ call: CAPPluginCall) {
        do {
            try implementation.configure(options: call.options)
            call.resolve()
        } catch let error as IndeRunException {
            let contractError = error.toContractError()
            let details = try? implementation.encode(error: contractError)
            call.reject(contractError.message, contractError.errorClass.rawValue, error, details)
        } catch {
            let normalized = toIndeRunException(error)
            let contractError = normalized.toContractError()
            let details = try? implementation.encode(error: contractError)
            call.reject(contractError.message, contractError.errorClass.rawValue, normalized, details)
        }
    }

    @objc func run(_ call: CAPPluginCall) {
        Task {
            do {
                let result = try await implementation.run(requestObject: call.options)
                call.resolve(result)
            } catch let error as IndeRunException {
                let contractError = error.toContractError()
                let details = try? implementation.encode(error: contractError)
                call.reject(contractError.message, contractError.errorClass.rawValue, error, details)
            } catch {
                let normalized = toIndeRunException(error)
                let contractError = normalized.toContractError()
                let details = try? implementation.encode(error: contractError)
                call.reject(contractError.message, contractError.errorClass.rawValue, normalized, details)
            }
        }
    }
}
#endif
