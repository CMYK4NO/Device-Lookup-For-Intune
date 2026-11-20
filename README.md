# Device Lookup for Intune

A native macOS app for Intune administrators. Look up a user by UPN, or a device by name or serial number, and see its compliance, configuration, app and custom attribute status for macOS, Windows and Linux. Read-only by default, everything runs locally: no server, no account other than your own Entra sign-in, no client secret, and no third-party dependencies.


*Search a user, pick the devices, tick the attributes to read. Replace the screenshots in `docs/images/` with your own.*

## What it does

- **Search** by user principal name or by device name or serial number. The matching macOS, Windows and Linux devices are listed; iOS, iPadOS and Android have no custom attributes and are left out.
- **Read** the custom attributes of the selected devices: macOS custom attributes, Windows Remediations (detection output) and Linux custom compliance discovery scripts. Nothing is read until you choose Read.
- **Browse** any attribute from the sidebar and load every device's result, with a progress count, in a sortable, filterable table.
- **Check device status**: compliance policies, configuration profiles and managed apps for the selected devices, each read when you open its tab.
- **Inspect** a row: the full value, the Intune inventory serial and OS, and the raw JSON.
- **Export CSV** from either screen: UTF-8 with BOM, RFC 4180 quoting, ISO 8601 dates, and formula-injection protection for Excel and Numbers.
- **Passwords and keys** (optional): reveal and rotate the FileVault key, macOS LAPS, Windows LAPS and BitLocker keys, with explicit confirmation. See [Passwords and keys](#passwords-and-keys).

## Requirements

- macOS 13 Ventura or later to run the app.
- Xcode to build it (SwiftUI, Swift 5 language mode).
- A Microsoft Entra app registration of your own and an Intune role that can read devices and device configurations (see below).
- No third-party dependencies.

## Download

Get the latest build from the [Releases page](../../releases), unzip it and move **Device Lookup for Intune.app** to Applications. If the build is not notarized, Control-click the app and choose **Open** the first time, or use **System Settings > Privacy & Security > Open Anyway**. The app does not remove the quarantine flag or change any security setting for you. If you prefer not to run an unsigned build, build it from source.

## Build and run

1. Open `DeviceLookupForIntune.xcodeproj` in Xcode.
2. In Signing & Capabilities, choose your Team (or "Sign to Run Locally") and change the bundle identifier (`com.example.DeviceLookupForIntune` is a placeholder) to one you own.
3. Run with ⌘R, run the tests with ⌘U, or from Terminal:

```bash
xcodebuild -project DeviceLookupForIntune.xcodeproj -scheme DeviceLookupForIntune -destination 'platform=macOS' test
```

## First launch

No tenant is built in. On first launch, an administrator enters the **Tenant ID** and **Client ID** of their own Entra app registration in **Settings** (⌘,). Until both are filled in, *Sign in with Microsoft* stays disabled. The IDs are identifiers, not secrets; they are stored in this Mac's preferences, never in an export.

## Microsoft Entra app registration

1. Entra admin center > App registrations > New registration. Single tenant is fine. Leave the redirect URI empty for now.
2. Authentication > Add a platform > **Mobile and desktop applications**. Add the redirect URI `http://localhost` (exactly that, not `127.0.0.1`). Entra ignores the port for loopback redirects, so the app can pick a free one.
3. Authentication > Advanced settings > **Allow public client flows**: Yes.
4. API permissions > Add a permission > Microsoft Graph > **Delegated**:
   - `DeviceManagementConfiguration.Read.All`
   - `DeviceManagementManagedDevices.Read.All`
   - `DeviceManagementScripts.Read.All` (macOS custom attributes are scripts; without it Graph answers 403)
   - `DeviceManagementApps.Read.All` (requested only when you open Managed Apps)
   - Optional, for *Passwords and keys* (requested only when you reveal one): `DeviceLocalCredential.Read.All`, `BitlockerKey.Read.All`, `DeviceManagementManagedDevices.PrivilegedOperations.All`
   - The app also requests `openid`, `profile` and `offline_access` at every sign-in (the sign-in itself, your account name from the id token, and staying signed in while the app is open). They normally need no admin consent. If sign-in shows "Need admin approval" (often AADSTS65001 or AADSTS90094), add them under Microsoft Graph > Delegated as well and grant admin consent again.
5. Click **Grant admin consent** for the tenant (the Intune permissions require it).
6. Copy the **Directory (tenant) ID** and **Application (client) ID** into the app's Settings. Do not create a client secret.

## Intune RBAC role

The signed-in user needs an Intune role with **Read** on:

- **Device configurations** (custom attribute scripts, remediations, compliance scripts)
- **Managed devices**

The built-in *Read Only Operator* role covers both. A missing permission or role shows as a 403 in the app.

## Using the app

1. **Sign in** with *Sign in with Microsoft*. The browser opens; the app appears once you are signed in. The **Account** page shows who is signed in and has *Sign out*.
2. **Search by UPN** or **Search by Device**, press Search, select one or more devices, tick the attributes you want and choose **Read**. The results table shows Custom Attribute, Device, OS, Serial, Value, Result and Date, with an OS filter.
3. **Attributes** (sidebar): open macOS, Windows or Linux and select an attribute to load every device's result. Sort, filter by run state, and search by device, user, serial, OS version or value.
4. **Device status**: selecting devices in a search shows tabs for *Compliance*, *Configuration*, *Managed apps* and *Attributes*. Each tab is read when you open it, because Intune throttles quickly.
5. **Sidebar sections**: General (Account), Search (UPN, Device), then Compliance, Configurations, Managed Apps and Attributes, each with macOS, Windows and Linux.
6. **Copy**: right-click any row to copy one column or the whole row (tab-separated, so it pastes into separate cells). ⌘C copies the selected rows.
7. **Export CSV**: attributes export all rows or the filtered view; a search exports the table on screen. Default name `<os>-<attribute>-<yyyyMMdd-HHmm>.csv`.

## Passwords and keys

With macOS or Windows devices selected, a *Passwords and keys* panel lists them. Nothing is read until you choose *Reveal…* for a device and confirm.

- **macOS:** FileVault recovery key and macOS LAPS password. **Windows:** Windows LAPS password and BitLocker recovery keys.
- Values are masked. *Show* unmasks, *Copy* copies to this Mac only (not Universal Clipboard), marks the value as concealed and clears the clipboard after 60 seconds.
- They live in memory only, are never logged, are not part of CSV exports, and are dropped when the selection changes or you sign out.
- Every reveal is recorded in the Entra and Intune audit logs.
- **Rotate** sends the Intune remote action after a confirmation. This is the only place the app writes anything.

Needed permissions: **Enrollment programs > View macOS admin password** (macOS LAPS) and the permission to view FileVault keys (Remote tasks) in Intune, plus an Entra role that can read Windows LAPS passwords and BitLocker keys (for example Cloud Device Administrator or Helpdesk Administrator). To rotate, the matching Intune *Remote tasks* permissions.

## Privacy and security

- OAuth 2.0 authorization code flow with PKCE (S256) against Microsoft Entra ID v2.0, as a public client, in your default browser. No embedded web view and no client secret.
- The redirect is `http://localhost:<port>`; the app listens on a free loopback port for that one redirect, then stops.
- Nothing is persisted: the refresh token and account live in memory only, never in the Keychain or on disk. You sign in again after each launch.
- Graph and sign-in requests use an ephemeral URL session, so no response (passwords and keys included) is cached on disk.
- Logging uses `os.Logger` (subsystem `DeviceLookupForIntune`). Requests are logged with method, path, status and duration, never the query or a token.
- The app is sandboxed (network client and server for the loopback redirect, user-selected file write for CSV).

## Known limitations

- All Graph sources are **beta** endpoints and can change without notice.
- **Linux:** the script list loads, but `deviceComplianceScripts/{id}/deviceRunStates` returned `400 No OData route exists` in the tested tenant, so Linux custom compliance results cannot be read from that endpoint. Linux attributes show a message instead; macOS and Windows are not affected.
- **Windows** (remediations) reads `preRemediationDetectionScriptOutput`. If the field is empty the app shows all populated fields. Field names live in `Graph/OSSourceConfig.swift`; use the raw JSON of a row to find the right one.
- Graph's expanded `managedDevice` returns `serialNumber` and `operatingSystem` as null, so the app fills them from the device inventory.
- Search by UPN and Search by Device read every device's run states of each ticked attribute, which can be slow and throttled (HTTP 429) in a large tenant. The app retries with backoff and keeps a read for 15 minutes. Tick only the attributes you need.
- Several report endpoints (compliance, configuration, app install status) are undocumented or beta and their column names were taken from Microsoft documentation and community answers; they may change.
- The session is kept in memory only: you sign in again each time the app starts.

## License

See [LICENSE](LICENSE).
