/**
 * Service to inspect and monitor network connectivity status.
 */
export interface ConnectivityService {
  /**
   * Resolves to true if the host is connected to the network, false otherwise.
   */
  isOnline(): Promise<boolean>;
}

/**
 * Operating system thermal states denoting system heat and throttling risk.
 */
export type ThermalState = "nominal" | "fair" | "serious" | "critical";

/**
 * Service to inspect host device battery, power, and thermal constraints.
 */
export interface DeviceConstraintsService {
  /**
   * Retrieves the current thermal state of the device, if supported.
   */
  getThermalState?(): Promise<ThermalState>;
  /**
   * Checks if the host device has low power mode enabled, if supported.
   */
  isLowPowerModeEnabled?(): Promise<boolean>;
}

/**
 * Secure storage interface to store and retrieve sensitive credentials/tokens
 * without exposing them to request payloads.
 */
export interface SecureStorageService {
  /**
   * Gets a secret by its unique slot identifier.
   */
  getSecret?(slotId: string): Promise<string | null>;
  /**
   * Securely saves a secret under a unique slot identifier.
   */
  setSecret?(slotId: string, secret: string): Promise<void>;
  /**
   * Deletes a secret by its slot identifier.
   */
  deleteSecret?(slotId: string): Promise<void>;
}

/**
 * Service providing clocks for request timeouts and execution timing telemetry.
 */
export interface ClockService {
  /**
   * Returns current UNIX timestamp in milliseconds.
   */
  now(): number;
  /**
   * Returns monotonic high-resolution time in milliseconds.
   */
  monotonicNow?(): number;
}

/**
 * Registry of platform-specific host services utilized by the Engine Core.
 * Evaluates execution capabilities and manages OS-level boundaries.
 */
export interface HostServices {
  /**
   * Network connectivity service.
   */
  connectivity: ConnectivityService;
  /**
   * Device constraints service.
   */
  deviceConstraints?: DeviceConstraintsService;
  /**
   * Secure storage service.
   */
  secureStorage?: SecureStorageService;
  /**
   * Clock service.
   */
  clock?: ClockService;
}
