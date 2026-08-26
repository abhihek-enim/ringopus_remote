// Persistent, spoof-resistant device identity: replaces the retired
// MAC-derived device_id.rs. A single 16-byte MasterKey (CSPRNG-generated,
// the only thing ever persisted -- see lib/identity_store.dart)
// deterministically derives the JID localpart, XMPP password, and permanent
// connect code via HKDF-SHA-256 with domain-separated `info` strings, so
// reinstall-recovery is "the MasterKey survived" rather than "some struct of
// derived values survived". See decision.md ("Persistent MasterKey-derived
// device identity") for the full design rationale, and
// ~/.claude/plans/vast-dreaming-haven.md for the plan this implements.

use hkdf::Hkdf;
use sha2::Sha256;

/// Fixed, hardcoded, identical for every derivation below. This is NOT a
/// secret and NOT randomized -- HKDF's salt here exists only to namespace
/// this application's use of the MasterKey away from any other hypothetical
/// use of the same bytes. Randomizing it would make derivation
/// non-reproducible and defeat the entire point: the whole design depends on
/// the same MasterKey always producing the same JID/password/code.
const HKDF_SALT: &[u8] = b"oojack-hkdf-salt-v1";

const MASTER_KEY_BYTES: usize = 16;

pub struct DeviceIdentity {
    pub jid_localpart: String,
    pub xmpp_password: String,
    pub connect_code: String,
}

/// 16 bytes from a CSPRNG, hex-encoded. This is the ONE thing ever persisted
/// (see lib/identity_store.dart) -- JID/password/connect code are always
/// re-derived fresh from it, never cached.
pub fn generate_master_key() -> Result<String, String> {
    let mut bytes = [0u8; MASTER_KEY_BYTES];
    getrandom::getrandom(&mut bytes).map_err(|e| format!("CSPRNG failure: {e}"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Pure function of master_key_hex -- no I/O, no randomness beyond the
/// deterministic re-derivation loop in derive_connect_code, fully
/// reproducible. Same MasterKey always produces the same DeviceIdentity.
pub fn derive_identity(master_key_hex: String) -> Result<DeviceIdentity, String> {
    let master_key_bytes = decode_master_key(&master_key_hex)?;
    let hk = Hkdf::<Sha256>::new(Some(HKDF_SALT), &master_key_bytes);

    let mut jid_bytes = [0u8; 16];
    hk.expand(b"oojack-jid-v1", &mut jid_bytes)
        .map_err(|e| format!("HKDF expand (jid) failed: {e}"))?;
    let jid_localpart = jid_bytes.iter().map(|b| format!("{b:02x}")).collect();

    let mut password_bytes = [0u8; 32];
    hk.expand(b"oojack-xmpp-password-v1", &mut password_bytes)
        .map_err(|e| format!("HKDF expand (password) failed: {e}"))?;
    let xmpp_password = base64_url_encode(&password_bytes);

    let connect_code = derive_connect_code(&hk)?;

    Ok(DeviceIdentity {
        jid_localpart,
        xmpp_password,
        connect_code,
    })
}

/// The largest multiple of 10^12 that fits in a u64 -- (u64::MAX / 10^12) *
/// 10^12. A draw >= this value would bias the modulo reduction below (2^64
/// mod 10^12 = 73_709_551_616, i.e. ~7.4% of the output space would be
/// ~5.4e-8 relatively more likely than the rest). Immaterial for a
/// non-secret locator, but rejection sampling is cheap enough that there is
/// no reason to accept an avoidable bias for free.
const CONNECT_CODE_REJECTION_THRESHOLD: u64 = 18_446_744_000_000_000_000;
const CONNECT_CODE_MODULUS: u64 = 1_000_000_000_000;
const CONNECT_CODE_MAX_ATTEMPTS: u8 = 16;

fn derive_connect_code(hk: &Hkdf<Sha256>) -> Result<String, String> {
    for attempt in 0u8..CONNECT_CODE_MAX_ATTEMPTS {
        // Re-deriving with a different info string is not "randomness" --
        // each attempt is a distinct, fixed HKDF-Expand call, so the whole
        // function stays a pure, deterministic function of the MasterKey
        // alone (the same MasterKey always lands on the same attempt
        // index). This is rejection sampling over deterministic candidates,
        // not a retry over live entropy.
        let info = format!("oojack-connect-code-v1:{attempt}");
        let mut candidate_bytes = [0u8; 8];
        hk.expand(info.as_bytes(), &mut candidate_bytes)
            .map_err(|e| format!("HKDF expand (connect code) failed: {e}"))?;
        let candidate = u64::from_be_bytes(candidate_bytes);
        if candidate < CONNECT_CODE_REJECTION_THRESHOLD {
            return Ok(format!("{:012}", candidate % CONNECT_CODE_MODULUS));
        }
    }
    // P(a single draw is rejected) ~= 5.4e-8; P(all CONNECT_CODE_MAX_ATTEMPTS
    // draws rejected) ~= (5.4e-8)^16 -- not a real operational concern, but
    // this must fail explicitly rather than loop forever or silently accept
    // a biased value.
    Err("connect code derivation exhausted rejection-sampling attempts".into())
}

fn decode_master_key(master_key_hex: &str) -> Result<[u8; MASTER_KEY_BYTES], String> {
    if master_key_hex.len() != MASTER_KEY_BYTES * 2
        || !master_key_hex.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(format!(
            "MasterKey must be exactly {} lowercase hex characters",
            MASTER_KEY_BYTES * 2
        ));
    }
    let mut out = [0u8; MASTER_KEY_BYTES];
    for (i, slot) in out.iter_mut().enumerate() {
        *slot = u8::from_str_radix(&master_key_hex[i * 2..i * 2 + 2], 16)
            .map_err(|e| format!("invalid MasterKey hex: {e}"))?;
    }
    Ok(out)
}

fn base64_url_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 12) & 0x3f) as usize] as char);
        if chunk.len() > 1 {
            out.push(ALPHABET[((n >> 6) & 0x3f) as usize] as char);
        }
        if chunk.len() > 2 {
            out.push(ALPHABET[(n & 0x3f) as usize] as char);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pinned test vector (spec Section 4's intent, satisfied without a
    /// second implementation to keep in sync -- the Orchestrator never
    /// re-derives anything, see server/deviceIdentity.js). A golden
    /// reference for any future re-implementation or debugging tool --
    /// cheap to have now, expensive to reconstruct later. Recorded in
    /// decision.md too.
    #[test]
    fn known_master_key_produces_pinned_identity() {
        // Golden reference, also recorded in decision.md. If this test ever
        // needs to change (e.g. a deliberate salt/info-string revision),
        // that's a breaking change to every already-provisioned device's
        // identity and must be called out as such, not adjusted quietly.
        let master_key = "00".repeat(MASTER_KEY_BYTES);
        let identity = derive_identity(master_key).expect("derivation should succeed");
        assert_eq!(identity.jid_localpart, "1a4e22dc593f992b3182d31771b32585");
        assert_eq!(identity.xmpp_password, "nmfvsgJ4ViehqDbpAH5UhtJssEQiRNPcQuhIOezUp0E");
        assert_eq!(identity.connect_code, "833395682787");
    }

    #[test]
    fn different_master_keys_produce_different_identities() {
        let a = derive_identity("11".repeat(MASTER_KEY_BYTES)).unwrap();
        let b = derive_identity("22".repeat(MASTER_KEY_BYTES)).unwrap();
        assert_ne!(a.jid_localpart, b.jid_localpart);
        assert_ne!(a.xmpp_password, b.xmpp_password);
        assert_ne!(a.connect_code, b.connect_code);
    }

    #[test]
    fn rejects_malformed_master_key() {
        assert!(derive_identity("not-hex-not-hex-not-hex-not-hex".into()).is_err());
        assert!(derive_identity("00".repeat(15)).is_err());
    }

    #[test]
    fn connect_codes_are_valid_12_digit_numbers_under_the_modulus() {
        for i in 0u8..50 {
            let key = format!("{i:02x}").repeat(MASTER_KEY_BYTES);
            let identity = derive_identity(key).unwrap();
            let as_number: u64 = identity.connect_code.parse().expect("must be numeric");
            assert!(as_number < CONNECT_CODE_MODULUS);
        }
    }

    #[test]
    fn generated_master_keys_are_well_formed_and_unique() {
        let a = generate_master_key().unwrap();
        let b = generate_master_key().unwrap();
        assert_eq!(a.len(), MASTER_KEY_BYTES * 2);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }
}
