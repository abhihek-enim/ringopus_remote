// MAC-derived customer device identity (Customer Identity v2 — see
// ~/.claude/plans/prompt-plan-multi-session-support-distributed-nova.md,
// Part A). Deliberately simple compared to the superseded TPM/Secure-Enclave
// design: this is a self-reported, spoofable value by design — persistence
// downstream is consent-gated per session, not a security mechanism, so a
// stronger identity primitive isn't needed here.
//
// `network-interface` enumerates NICs on Windows/macOS uniformly; it exposes
// no is-wifi/is-ethernet flag and no up/running flag, so both are inferred
// via best-effort heuristics below (name-substring classification, "has an
// assigned IP" as a proxy for "currently active"). Multi-adapter machines
// (Ethernet + Wi-Fi + VPN + virtual switches) are common and this heuristic
// is not guaranteed to pick the adapter a user would call "primary" - that
// limitation is accepted, not engineered around (see the plan's Part A).
//
// adapterKind travels alongside deviceId on every downstream use (wire
// message, on-screen AppLog) specifically so a rotation-prone Wi-Fi-based id
// is distinguishable from a stable wired one after the fact - Windows
// "Random hardware addresses" and macOS "Private Wi-Fi Address" both rewrite
// what local OS interface queries themselves return for a Wi-Fi adapter under
// default settings, so a Wi-Fi-sourced deviceId may not be stable across
// sessions/reinstalls even though this code reads it correctly each time.

use network_interface::{NetworkInterface, NetworkInterfaceConfig};
use sha2::{Digest, Sha256};

pub struct DeviceIdInfo {
    pub device_id: String,
    pub adapter_kind: String,
}

const VIRTUAL_NAME_HINTS: [&str; 11] = [
    "vmware",
    "virtualbox",
    "vbox",
    "hyper-v",
    "tap",
    "tun",
    "utun",
    "npcap",
    "docker",
    "wsl",
    "bridge",
];

pub fn get_device_id() -> Result<DeviceIdInfo, String> {
    let interfaces = NetworkInterface::show()
        .map_err(|e| format!("failed to enumerate network interfaces: {e}"))?;

    let candidates: Vec<(&NetworkInterface, &str)> = interfaces
        .iter()
        .filter(|i| !i.internal)
        .filter_map(|i| {
            let mac = i.mac_addr.as_deref()?;
            if is_zero_mac(mac) {
                None
            } else {
                Some((i, mac))
            }
        })
        .collect();

    let chosen: (&NetworkInterface, &str) = pick(&candidates, "ethernet")
        .or_else(|| pick(&candidates, "wifi"))
        .or_else(|| pick(&candidates, "unknown"))
        .or_else(|| candidates.iter().find(|(i, _)| has_ip(i)).copied())
        .or_else(|| candidates.first().copied())
        .ok_or_else(|| "no usable network interface with a MAC address was found".to_string())?;

    let (iface, mac) = chosen;
    let adapter_kind = classify(&iface.name).to_string();
    let mac_bytes = parse_mac(mac)?;

    let mut hasher = Sha256::new();
    hasher.update(mac_bytes);
    let digest = hasher.finalize();
    let device_id = digest.iter().map(|b| format!("{b:02x}")).collect::<String>();

    Ok(DeviceIdInfo {
        device_id,
        adapter_kind,
    })
}

fn pick<'a>(
    candidates: &'a [(&'a NetworkInterface, &'a str)],
    kind: &str,
) -> Option<(&'a NetworkInterface, &'a str)> {
    candidates
        .iter()
        .find(|(i, _)| classify(&i.name) == kind && has_ip(i))
        .copied()
}

// network-interface exposes no up/running flag; an interface with no
// assigned address at all is treated as not currently active.
fn has_ip(iface: &NetworkInterface) -> bool {
    !iface.addr.is_empty()
}

fn classify(name: &str) -> &'static str {
    let lower = name.to_lowercase();
    if VIRTUAL_NAME_HINTS.iter().any(|h| lower.contains(h)) {
        return "virtual";
    }
    if lower.contains("wi-fi") || lower.contains("wifi") || lower.contains("wlan") || lower.contains("wireless") {
        return "wifi";
    }
    if lower.contains("ethernet") || lower.starts_with("eth") {
        return "ethernet";
    }
    "unknown"
}

fn is_zero_mac(mac: &str) -> bool {
    mac.chars().all(|c| c == '0' || c == ':' || c == '-')
}

fn parse_mac(mac: &str) -> Result<[u8; 6], String> {
    let bytes: Vec<u8> = mac
        .split(|c| c == ':' || c == '-')
        .map(|part| {
            u8::from_str_radix(part, 16).map_err(|e| format!("invalid MAC segment '{part}': {e}"))
        })
        .collect::<Result<Vec<u8>, String>>()?;
    bytes
        .try_into()
        .map_err(|v: Vec<u8>| format!("MAC address '{mac}' had {} segments, expected 6", v.len()))
}
