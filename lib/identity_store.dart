import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistence for the app's device identity. Exactly one secret (the
/// MasterKey) is ever written to OS secure storage — the JID, XMPP
/// password, and permanent connect code are always re-derived fresh from it
/// (see `rust/src/api/persistent_identity.rs`), never separately cached.
/// See decision.md ("Persistent MasterKey-derived device identity") and
/// ~/.claude/plans/vast-dreaming-haven.md for the full design.
class IdentityStore {
  IdentityStore._();

  static const _secureStorage = FlutterSecureStorage(
    // Same config as the original persistent-identity work — still
    // required on unsigned local/dev builds (errSecMissingEntitlement);
    // a properly signed, provisioned production build should use the
    // stronger Data Protection keychain instead. See decision_log.md.
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  static const _masterKeyKey = 'oojack_master_key';
  static const _wasProvisionedKey = 'oojack_was_ever_provisioned';

  // Legacy (pre-MasterKey) keys, written by the old `sha256(mac)`-based
  // _provisionDeviceIdentity() — read-only here, needed only by the
  // migration path.
  static const _legacyJidKey = 'device_identity_jid';
  static const _legacyPasswordKey = 'device_identity_password';

  /// The one secret. Never read JID/password/connect-code back from
  /// storage anywhere else in the app — always re-derive them fresh from
  /// this via `derive_identity()`.
  static Future<String?> loadMasterKey() =>
      _secureStorage.read(key: _masterKeyKey);

  static Future<void> persistMasterKey(String masterKeyHex) =>
      _secureStorage.write(key: _masterKeyKey, value: masterKeyHex);

  /// Only ever called from an explicit, user-confirmed "Reset identity"
  /// action (see producer_home_page.dart) — never automatically. Clearing
  /// this without immediately persisting a freshly generated replacement
  /// would otherwise let a crash land the app in the lost-identity recovery
  /// state, which is why the reset flow always regenerates before clearing.
  static Future<void> clearMasterKey() =>
      _secureStorage.delete(key: _masterKeyKey);

  /// Plain (non-secure) local storage — a boolean, not a secret. This is
  /// what lets a later launch tell "identity was never provisioned" apart
  /// from "identity WAS provisioned and the MasterKey is now missing" — the
  /// two situations the Migration state machine must handle completely
  /// differently (silently create vs. surface an explicit recovery state).
  static Future<bool> wasEverProvisioned() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_wasProvisionedKey) ?? false;
  }

  static Future<void> markProvisioned() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_wasProvisionedKey, true);
  }

  /// Read-only access to the existing (pre-migration) secure-storage keys,
  /// already written by the currently-live `_provisionDeviceIdentity()`.
  /// Needed only by the Migration state machine, never by normal
  /// steady-state launch.
  static Future<({String jid, String password})?> loadLegacyCredentials() async {
    final jid = await _secureStorage.read(key: _legacyJidKey);
    final password = await _secureStorage.read(key: _legacyPasswordKey);
    if (jid == null || password == null) return null;
    return (jid: jid, password: password);
  }

  static Future<void> clearLegacyCredentials() async {
    await _secureStorage.delete(key: _legacyJidKey);
    await _secureStorage.delete(key: _legacyPasswordKey);
  }
}
