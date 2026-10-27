# Rancangan Penambahan Fitur — Titanium Browser Fork

> Hasil audit repo `zuher5/titanium-browser-fork` (Chromium 156.0.8078.47, basis Vanadium)
> Dua fitur: **(1) Install shortcut (Add to Home screen)** dan **(2) Toggle "Allow app links to open in apps outside of Titanium"**.

---

## 1. Ringkasan Hasil Audit

### 1.1 Arsitektur repo

Repo ini **bukan source browser**, melainkan *build-config repo* yang merakit Chromium dari tiga sumber:

| Komponen | Lokasi | Peran |
|---|---|---|
| Chromium upstream | di-fetch saat build (tag `156.0.8078.47`) | Source utama |
| Vanadium patches | submodule `vanadium/` (pinned `2ae4335`) + `build.sh` | 305 patch hardening/rebranding, di-`git am` ke tree Chromium |
| Titanium overrides | `patch.sh` (sed satu baris) + `args.gn` + `extensions/` | Perilaku khusus Titanium: scheme guard, MV2, off-store install, bundling Titanium Extension |

Alur `build.sh`:
1. Fetch Chromium tag → `git am vanadium/patches/*.patch` (setelah `replace()` menamai ulang `vanadium`→`titanium` di dalam file patch, sehingga file `vanadium/chromium_src/...` menjadi `titanium/chromium_src/...`).
2. `source patch.sh` → semua perubahan Titanium diterapkan sebagai **sed satu baris** ke tree Chromium (termasuk ke file `titanium/chromium_src/...` hasil rename).
3. `args.gn` disalin, build `chrome_public_apk`.

**Konsekuensi penting:** submodule `vanadium/` dipin ke commit upstream — file baru yang ditambahkan di dalamnya **tidak bisa di-commit di repo fork ini**. Semua penambahan Titanium selama ini hanya lewat sed di `patch.sh`. Untuk fitur baru berskala UI (toggle + strings + Java class), sed satu baris rapuh; rancangan ini mengusulkan direktori patch baru milik fork (§5).

### 1.2 Temuan per fitur

- **Install shortcut:** fitur upstream Chromium 156 **sudah ada** dan **tidak dilucuti oleh patch Vanadium/Titanium mana pun** (grep `AddToHome*` hanya menyentuh strings branding). Perlu verifikasi runtime, bukan implementasi dari nol (§3).
- **App link ke aplikasi eksternal:** saat ini **belum ada kontrol pengguna**. Chromium punya satu choke point yang cocok: `ExternalNavigationDelegate.shouldDisableExternalIntentRequestsForUrl()` (chrome layer, `return false;` statis) yang dikonsultasikan `ExternalNavigationHandler.externalIntentRequestsDisabledForUrl()` **tepat sebelum semua jalur** `OVERRIDE_WITH_EXTERNAL_INTENT`. Toggle bisa dipasang di sini tanpa menyentuh layer `components` (§4).

---

## 2. Fitur 1 — Install Shortcut (Add to Home screen)

### 2.1 Status upstream (M156)

- Item menu **"Add to Home screen…"** dibangun di `TabbedAppMenuPropertiesDelegate`
  (`chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/TabbedAppMenuPropertiesDelegate.java`),
  muncul di menu utama dan di submenu **Save & Share** (`buildAddToHomescreenListItem`).
- Visibilitas dikontrol `AppMenuPropertiesDelegateImpl.shouldShowHomeScreenMenuItem()`
  (`chrome/android/java/src/org/chromium/chrome/browser/app/appmenu/AppMenuPropertiesDelegateImpl.java:445`):

  ```java
  return WebappsUtils.isAddToHomeIntentSupported()
          && !isNativePage && !isFileScheme && !isContentScheme
          && !isIncognito && !url.isEmpty();
  ```

- Menekannya membuka **Universal Install bottom sheet** (pilihan *Install* untuk PWA atau *Create shortcut*). Strings `IDS_PWA_UNI_INSTALL_OPTION_SHORTCUT_*` masih utuh di tree.
- `LauncherShortcutActivity.java` dan `ShortcutHelper.java` juga masih ada di tree — jalur shortcut/PWA lengkap.

### 2.2 Analisis risiko di Titanium

Tidak ada patch yang menghapus fitur ini, tetapi dua kondisi fork bisa memengaruhi:

1. **`WebappsUtils.isAddToHomeIntentSupported()`** — butuh launcher yang menangani broadcast `INSTALL_SHORTCUT`. Pada launcher standar Android selalu true; hanya berpotensi false pada ROM/launcher eksotis.
2. **`is_desktop_android = true`** (args.gn) — bentuk UI (form factor desktop) bisa mengubah penempatan item menu; flag `DesktopAndroidLinkCapturing` default-nya aktif sehingga jalur "Open in App" ikut tersedia.

### 2.3 Rancangan

**Tahap A — Verifikasi (tanpa patch):** build APK, cek item menu di situs biasa & situs PWA (contoh: `https://web.dev`, `https://youtube.com`), mode normal (bukan incognito), non-native page.

**Tahap B — Patch fallback** (hanya jika item menu tidak tampil):
- Tambahkan patch `0001-ensure-add-to-homescreen-menu-item.patch` yang memaksa `shouldShowHomeScreenMenuItem()` mengembalikan `true` bila `WebappsUtils.isAddToHomeIntentSupported()` dan URL valid — atau, jika akar masalah `isAddToHomeIntentSupported`, paksa kembalinya `true` di `WebappsUtils`.
- **Tidak perlu** penambahan file/GN target baru; patch ≤ 5 baris.
- Lokasi patch: `patches/0001-*.patch` (lihat §5), diterapkan via `git am` setelah patch Vanadium.

Estimasi: 0–10 baris kode. Tidak ada setelan baru yang diperlukan (perilaku Chrome standar).

---

## 3. Fitur 2 — Toggle "Allow app links to open in apps outside of Titanium"

### 3.1 Pemahaman alur upstream

Dua jalur berbeda saat link bisa dibuka aplikasi lain:

1. **Handoff navigasi (app link / intent):** setiap navigasi melewati
   `ExternalNavigationHandler` (`components/external_intents/android/java/.../ExternalNavigationHandler.java`).
   Jika URL cocok dengan aplikasi terpasang (verified app link, `intent://`, custom scheme), handler mengembalikan
   `OverrideUrlLoadingResult.forExternalIntent()` → browser menyerahkan ke aplikasi (dengan dialog konfirmasi bila perlu).
2. **"Open in App" UI (link capturing desktop-Android):** item menu/entry point dari
   `chrome/browser/open_in_app/android/java/src/org/chromium/chrome/browser/open_in_app/`,
   tersedia bila `OpenInAppUtils.isOpenInAppAvailable()`
   → `ChromeFeatureList.sDesktopAndroidLinkCapturing.isEnabled() && DeviceInfo.isDesktop()`
   (flag default **true**; Titanium `is_desktop_android = true` → UI ini aktif).

**Catatan:** jalur masuk (aplikasi lain membuka link di Titanium) tidak tersentuh fitur ini — itu wilayah `LaunchIntentDispatcherHooks` + *scheme guard* yang sudah ada di `patch.sh` (reroute incognito, hanya `isNetworkUrl`). Fitur ini murni **arah keluar** (dari Titanium → aplikasi eksternal).

### 3.2 Titik hook terpilih

`ExternalNavigationHandler.externalIntentRequestsDisabledForUrl()` (baris ±1972) dipanggil
**sebelum semua jalur pengembalian `OVERRIDE_WITH_EXTERNAL_INTENT`**:

```java
// "This should come after file intents, but before any returns of OVERRIDE_WITH_EXTERNAL_INTENT."
if (externalIntentRequestsDisabledForUrl(params, targetIntent)) {
    return OverrideUrlLoadingResult.forNoOverride();   // navigasi tetap di browser
}
```

yang bertanya ke chrome layer:

```java
// chrome/android/java/src/org/chromium/chrome/browser/externalnav/ExternalNavigationDelegateImpl.java
@Override
public boolean shouldDisableExternalIntentRequestsForUrl(
        ExternalNavigationParams params, Intent intent) {
    return false;   // ← TITIK PATCH: ganti dengan baca pref toggle
}
```

Keunggulan titik ini: satu lokasi, chrome layer, tanpa patch `components/`, tanpa target GN baru, dan resultnya `NO_OVERRIDE` sehingga halaman tetap terbuka normal di Titanium.

### 3.3 Spesifikasi toggle

| Aspek | Nilai |
|---|---|
| Nama pref | `allow_app_links` (`SharedPrefsUtils.SharedPrefsExt.ALLOW_APP_LINKS`) |
| Tipe / default | `BoolSharedPref`, default **true** (paritas upstream; tidak mengubah perilaku sampai user mematikan) |
| Lokasi UI | **Settings → Privacy and security** (konsisten dengan toggle Titanium/Vanadium lain) |
| Widget | `ChromeSwitchPreference` (slider on/off, pola identik patch Vanadium `0155-Toggle-for-opening-external-links-in-incognito-tabs`) |
| Judul | "Allow app links to open in apps" |
| Ringkasan | "Allow links to open in installed apps outside Titanium" |
| OFF | navigasi http(s) tidak di-handoff ke aplikasi eksternal; item "Open in App" disembunyikan |
| ON | perilaku Chromium standar |

**Keputusan scope (perlu konfirmasi saat review):**
- **Direkomendasikan:** ketika OFF, blokir handoff untuk navigasi ber-scheme **http/https** (app link & link capturing) **dan** `intent://` ke package tertentu; **tetap izinkan** protokol murni `tel:`, `mailto:`, `sms:`, `geo:` agar fungsionalitas dasar tidak rusak. Implementasi: di dalam hook, periksa scheme `params.getUrl()`/`intent.getData()`.
- Alternatif sederhana: blokir semua external intent ketika OFF (satu baris `return !ALLOW_APP_LINKS.get();`) — paling minimal tetapi mematikan juga `tel:`/`mailto:`.

### 3.4 Rincian perubahan (5 file)

Semua mengikuti pola patch Vanadium `0155`. Ditulis sebagai git-am patches di `patches/` (§5).

**a) `titanium/chromium_src/base/android/java/src/org/chromium/base/shared_preferences/SharedPrefsUtils.java`**

```java
public static class SharedPrefsExt {
    ...
    public static final BoolSharedPref ALLOW_APP_LINKS =
            new BoolSharedPref("allow_app_links", true);
}
// + tambahkan ALLOW_APP_LINKS.getKey() ke isKeyInUse(...)
```

**b) Patch `chrome/android/java/src/org/chromium/chrome/browser/externalnav/ExternalNavigationDelegateImpl.java`**

```java
@Override
public boolean shouldDisableExternalIntentRequestsForUrl(
        ExternalNavigationParams params, Intent intent) {
    if (!SharedPrefsExt.ALLOW_APP_LINKS.get()) {
        return isAppLinkNavigation(params, intent);  // true utk http(s)/intent://, false utk tel:/mailto:/geo
    }
    return false;
}
```

(`isAppLinkNavigation` = helper statis kecil di file yang sama atau di `TabPreferencesUtils`; hanya scope-approval dari §3.3.)

**c) Patch `chrome/browser/open_in_app/android/java/src/org/chromium/chrome/browser/open_in_app/OpenInAppUtils.java`** — sembunyikan UI saat OFF:

```java
public static boolean isOpenInAppAvailable() {
    if (!SharedPrefsExt.ALLOW_APP_LINKS.get()) return false;
    return ChromeFeatureList.sDesktopAndroidLinkCapturing.isEnabled() && DeviceInfo.isDesktop();
}
```

**d) `titanium/chromium_src/chrome/android/java/res/xml/privacy_preferences_ext.xml`** — tambah entri:

```xml
<org.chromium.components.browser_ui.settings.ChromeSwitchPreference
    android:key="allow_app_links"
    android:title="@string/allow_app_links_title"
    android:summary="@string/allow_app_links_summary"
    android:persistent="false"/>
```

**e) `titanium/chromium_src/chrome/android/java/src/org/chromium/chrome/browser/privacy/settings/PrivacySettingsExt.java`** — daftarkan listener + update state (pola `OPEN_LINKS_IN_INCOGNITO` di patch `0155`): tambah konstanta `PREF_ALLOW_APP_LINKS`, cabang di `getListener`, dan blok di `updatePreferences`.

**f) `titanium/chromium_src/chrome/browser/ui/android/strings/android_chrome_ext_strings.grdp`** — dua message baru (`IDS_ALLOW_APP_LINKS_TITLE`, `IDS_ALLOW_APP_LINKS_SUMMARY`).

> Jika scope §3.3 dipilih "blokir semua", file (b) cukup satu baris `return !SharedPrefsExt.ALLOW_APP_LINKS.get();` dan helper tidak diperlukan.

### 3.5 Interaksi yang harus dijaga

- **`patch.sh` scheme guard** (3 sed pada `titanium/chromium_src/.../LaunchIntentDispatcherHooks.java`) tidak boleh diubah — itu jalur *inbound*; toggle ini jalur *outbound*.
- Sed `patch.sh` pada `PrivacySettingsExt.java` (`safelyRemovePreference(PREF_JAVASCRIPT_OPTIMIZER)`) berjalan **setelah** `git am` patch kita — pastikan string `PREF_JAVASCRIPT_OPTIMIZER` tidak muncul di baris tambahan kita (aman dengan nama `PREF_ALLOW_APP_LINKS`).
- Pref disimpan di `SharedPrefs` (bukan `PrefService`) mengikuti konvensi ext → otomatis tidak ikut sinkronisasi/pembersihan upstream.

---

## 4. Strategi Implementasi di Repo

Tiga opsi, direkomendasikan **Opsi B**:

| Opsi | Cara | Pro | Kontra |
|---|---|---|---|
| A | Fork GrapheneOS/Vanadium, tambah patch di sana, update pointer submodule | Paling bersih, rebase mudah | Harus maintain repo fork Vanadium lagi |
| **B (rekomendasi)** | Dir baru `patches/` di repo ini; `build.sh` menambahkan `git am $SCRIPT_DIR/patches/*.patch` setelah patch Vanadium | Semua di satu repo, kode sungguhan (bukan sed), survive version bump jauh lebih baik dari sed | Patch tetap perlu direbase tiap bump versi Chromium |
| C | Teruskan gaya `patch.sh` (sed/heredoc) | Konsisten dengan kode lama | Toggle + strings + XML + 2 patch file = terlalu rapuh untuk sed |

Perubahan `build.sh` untuk Opsi B (1 baris, setelah `git am ... vanadium/patches/*.patch`):

```sh
git am --whitespace=nowarn --keep-non-patch $SCRIPT_DIR/patches/*.patch
```

Urutan penerapan: `vanadium/patches` (dengan rename vanadium→titanium) → `patches/` (sudah ditulis dengan path final `titanium/chromium_src/...` untuk file baru, path upstream biasa untuk file Chromium yang diubah) → `patch.sh` (sed).

---

## 5. Rencana Pengujian

1. **Build CI:** jalankan workflow build arm64 (GitHub Actions), pastikan `git am` tidak konflik.
2. **Fitur 1 (install shortcut):**
   - Situs biasa → ⋮ → *Save & Share* → *Add to Home screen* → pilih *Create shortcut* → shortcut muncul & membuka Titanium.
   - Situs PWA (mis. `youtube.com`) → *Install* → app ter-install & dapat launch dari launcher.
   - Pastikan **tidak** tampil di tab incognito dan di `chrome://` pages.
3. **Fitur 2 (toggle app links):**
   - Default (ON): buka `youtube.com` di Titanium, "Open in App" tersedia; link YouTube terbuka di aplikasi YouTube.
   - Matikan toggle → item "Open in App" hilang; navigasi link YouTube tetap di Titanium; `tel:` dari `tel:`-link tetap membuka dialer (bila scope §3.3 direkomendasikan dipakai).
   - Toggle ON kembali → perilaku normal tanpa restart.
   - Verifikasi pref bertahan setelah restart aplikasi (SharedPreferences).
4. **Regresi:** reroute incognito dari aplikasi eksternal tetap bekerja (scheme guard utuh); Custom Tab dari aplikasi lain tidak terpengaruh.

## 6. Risiko

- **Rebase versi:** `ExternalNavigationDelegateImpl.java` dan `ExternalNavigationHandler.java` sering berubah upstream — patch kecil tapi harus dicek tiap bump (praktik yang sudah dilakukan fork untuk 300 patch Vanadium).
- **Perbedaan perilaku user:** default ON menjamin tidak ada perubahan perilaku bagi pengguna existing; OFF adalah keputusan eksplisit user.
- **Dialog verifikasi app link Android** (Digital Asset Links) berada di level OS untuk arah masuk; di luar kendali browser — dokumen ini hanya mengatur arah keluar dari Titanium.

## 7. Checklist Eksekusi

- [x] Tambah `patches/0001-Toggle-for-allowing-app-links-to-open-in-external-ap.patch` (6 perubahan §3.4 dalam 1 patch; sudah terverifikasi apply bersih via `git am` terhadap state post-patch Vanadium)
- [ ] Tambah `patches/0002-ensure-add-to-homescreen-*.patch` (kondisional, hasil verifikasi §2.3 Tahap A — hanya jika item menu tidak tampil di APK)
- [x] Tambah 1 baris `git am` di `build.sh`
- [ ] Build CI arm64 + uji manual daftar §5
- [ ] (Opsional) dokumentasikan toggle di README bagian *Usage*

### Status implementasi (2026-10-27)

Fitur 2 (toggle app links) **sudah diimplementasikan** sesuai Opsi B dengan scope §3.3 yang direkomendasikan:
- Pref `allow_app_links`, default **true** (perilaku Chromium standar sampai user mematikan).
- OFF memblokir handoff http(s)/`intent://`/custom scheme; `tel:`, `mailto:`, `sms:`, `geo:` tetap berfungsi (lihat `isAppLinkNavigation()` di patch).
- Item "Open in App" disembunyikan saat OFF via `OpenInAppUtils.isOpenInAppAvailable()`.
- UI slider di Settings → Privacy and security, pola identik toggle "Open external links in incognito".
