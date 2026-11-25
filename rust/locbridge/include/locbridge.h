#ifndef LOCBRIDGE_H
#define LOCBRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LocBridgeResult {
    int32_t code;   /* 0 = OK, non-zero = error */
    char *message;  /* UTF-8 string allocated by Rust; free with locbridge_free_string */
} LocBridgeResult;

/// Connects to the local device over LocalDevVPN (default host_ip: "10.7.0.1")
/// supporting both iOS 26/27 Remote Pairing (.rppairing / plist with public_key/private_key)
/// and legacy Lockdown pairing files (.plist / .mobiledevicepairing).
/// Pass rp_port = 0 to auto-try default Remote Pairing ports (49152+).
LocBridgeResult locbridge_connect(
    const char *host_ip,
    uint16_t rp_port,
    const uint8_t *pairing_bytes,
    size_t pairing_len
);

/// Sets the simulated GPS coordinates on the connected device and keeps them active.
LocBridgeResult locbridge_set_location(double latitude, double longitude);

/// Clears the simulated GPS location, restoring the device's real GPS.
LocBridgeResult locbridge_clear_location(void);

/// Disconnects the active developer tunnel session.
LocBridgeResult locbridge_disconnect(void);

/// Returns 1 if a session is currently connected, 0 otherwise.
int32_t locbridge_is_connected(void);

/// Frees a message string returned inside LocBridgeResult.
void locbridge_free_string(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* LOCBRIDGE_H */
