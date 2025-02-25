# Windows ms-cxh and ms-cxh-full Protocol Handlers

CXH is abbreviation for **Cloud Experience Host**.

The `ms-cxh://` protocol is a custom handler for the Windows Out-of-Box Experience (OOBE) and Cloud Experience Host (CXH). It provides shortcuts to various Windows functionality pages, primarily for internal or administrative use.

## General Information

These protocol handlers are undocumented by Microsoft and can be used to launch specific dialog boxes and wizards in Windows.

I have no idea how long they will be supported, and in which Windows Versions they are supported, so I suggest using them  cautiously.

Some Reference sites:

* <https://www.hexacorn.com/blog/2022/01/16/ms-cxh-and-ms-cxh-full-handlers/>
* <https://enderman.ch/blog/the-windows-oobe>

## mc-cxh vs ms-cxh-full

There are two ways of starting each protocol, one normal and one fullscreen.

* Normal example:
  * `ms-cxh://NTHAADORMDM?ngc=enabled`
* Fullscreen Example:
  * `ms-cxh-full://NTHAADORMDM?ngc=enabled`

The `ms-cxh-full://` protocol can lead to some issues when used since the fullscreen is configured to be **Always on top**, meaning that some mental computer acrobatics are required to get it to close again.

### Recover from ms-cxh-full

* Running `ms-cxh-full://foo` or `ms-cxh-full://0` can lock up the desktop (always on top)
* It can blocks any window from being visible/interactive
* To recover, use one of the following:
  * Press WIN+R and run `taskkill /f /im UserOOBEBroker.exe`
  * Press WIN+R and run `powershell.exe -c "Get-process -Name UserOOBEBroker.exe | Stop-Process -Force"`

If the recovery command doesn't work, perform the last stepd in the next section.

### If stuck on the `WHFB Set Pin` during Autopilot enrollment

* Open Task manager ising `ctrl+alt+delete` or using `Ctrl+shift+esc`
* Use `alt+tab` to validate that it's open and in focus (The Whfb screen will be always on top, so yo can't see what you're doing.)
* Press `Alt then N` this opens the "new task" prompt in task manager.
* Type `Cmd or Powershell` and press `enter`
* Chech that the new window has launched with alt+tab
* Write and run command(s):
  * `Get-Process -Name WWA* | Stop-Process -Force`

That should kill the fullscreen WHFB set Pin Prompt and allow you to complete the login.

## List of Protocol Categories

I tried to create a comprehensive list of what they are and what they do. Note that a lot of them seemingly overlap in what they techincally do (several for setting or resetting PIN etc). So use them cautiously, I have no idea what context they might need to work properly.

### Out-of-Box Experience

| Command | Description |
|---------|-------------|
| `ms-cxh://FRX/AAD` | Azure Active Directory first run experience |
| `ms-cxh://FRX/INCLUSIVE` | Standard inclusive first run experience |
| `ms-cxh://FRX/INCLUSIVE?start=OobeProvisioningStatus` | First run experience starting at provisioning status page |
| `ms-cxh://FRX/TEAMEDITION` | Team edition first run experience |
| `ms-cxh://FRXRDXINCLUSIVE` | Retail demo experience inclusive mode |

### Microsoft Azure

| Command | Description |
|---------|-------------|
| `ms-cxh://AADPINRESETAUTH` | Azure AD PIN reset authentication |
| `ms-cxh://AADSSPR` | Azure AD Self-Service Password Reset |
| `ms-cxh://AADWEBAUTH` | Azure AD web authentication |

### Modern Settings

| Command | Description |
|---------|-------------|
| `ms-cxh://MOSET/AADLOCAL` | Azure AD local modern settings |
| `ms-cxh://MOSET/CONNECTTOWORK` | Connect to work settings |
| `ms-cxh://mosetmamconnecttowork?mode=mdm&username=%s&servername=%s` | Mobile Application Management connect to work with parameters |
| `ms-cxh://mosetmdmconnecttowork` | Mobile Device Management connect to work |
| `ms-cxh://MOSETMSA` | Microsoft account modern settings |
| `ms-cxh://MOSETMSALOCAL` | Microsoft account local modern settings |

### Microsoft Account

| Command | Description |
|---------|-------------|
| `ms-cxh://MSACFLPINRESET` | Microsoft account Change First Logon PIN reset |
| `ms-cxh://MSACFLPINRESETSIGNIN` | Microsoft account PIN reset sign-in |
| `ms-cxh://MSACXSIGNINAUTHONLY` | Microsoft account sign-in authentication only |
| `ms-cxh://MSACXSIGNINPINADD` | Microsoft account sign-in PIN add |
| `ms-cxh://MSACXSIGNINPINRESET` | Microsoft account sign-in PIN reset |
| `ms-cxh://MSAPINENROLL` | Microsoft account PIN enrollment |
| `ms-cxh://MSAPINRESET` | Microsoft account PIN reset |
| `ms-cxh://MSARDX` | Microsoft account retail demo experience |
| `ms-cxh://MSASSPR` | Microsoft account self-service password reset |

### Windows Hello for Microsoft Intune

| Command | Description |
|---------|-------------|
| `ms-cxh://NTH` | Intune Hello main page |
| `ms-cxh://NTH/AADRECOVERY` | Azure AD recovery for Intune Hello |
| `ms-cxh://NTHAADNGCFIXME` | Fix Azure AD Next Generation Credential issues |
| `ms-cxh://NTHAADNGCONLY` | Azure AD Next Generation Credential only mode |
| `ms-cxh://NTHAADNGCRESET` | Reset Azure AD Next Generation Credential |
| `ms-cxh://NTHAADNGCRESETDESTRUCTIVE` | Destructive reset of Azure AD NGC |
| `ms-cxh://NTHAADNGCRESETNONDESTRUCTIVE` | Non-destructive reset of Azure AD NGC |
| `ms-cxh://NTHAADORMDM?ngc=enabled` | Azure AD or MDM with NGC enabled |
| `ms-cxh://NTHENTNGCFIXME` | Fix Enterprise Next Generation Credential issues |
| `ms-cxh://NTHENTNGCONLY` | Enterprise Next Generation Credential only mode |
| `ms-cxh://NTHENTNGCRESET` | Reset Enterprise Next Generation Credential |
| `ms-cxh://NTHENTNGCRESETDESTRUCTIVE` | Destructive reset of Enterprise NGC |
| `ms-cxh://NTHENTORMDM` | Enterprise or MDM |
| `ms-cxh://NTHENTORMDM?ngc=enabled` | Enterprise or MDM with NGC enabled |
| `ms-cxh://NTHNGCUPSELL` | Next Generation Credential upsell page |
| `ms-cxh://NTHPRIVACY` | Intune Hello privacy settings |

### Second-chance OOBE

| Command | Description |
|---------|-------------|
| `ms-cxh://SCOOBE` | Second chance Out-of-Box Experience |
| `ms-cxh://SCOOBE%ws` | Second chance OOBE with parameters |
| `ms-cxh://SCOOBE/UPGRADE` | Second chance OOBE for upgrade scenarios |

### Cloud Settings

| Command | Description |
|---------|-------------|
| `ms-cxh://SETADDLOCALONLY` | Add local user only |
| `ms-cxh://SETADDNEWUSER` | Opens dialog to create a new user account |
| `ms-cxh://SETCHANGEPWD` | Opens dialog to change password |
| `ms-cxh://SETPHONEPAIRING` | Phone pairing settings |
| `ms-cxh://SETPHONEPAIRING?scenarioId=SwiftKeyCloudClipboard` | SwiftKey cloud clipboard phone pairing |
| `ms-cxh://setsqsalocalonly` | SQL Server Authentication local only |

### Miscellaneous

| Command | Description |
|---------|-------------|
| `ms-cxh://RDXRACSKUINCLUSIVE` | Retail demo experience inclusive SKU |
| `ms-cxh://TSET/ADDFAMILY` | Add family member |
| `ms-cxh://WLT` | Windows License Terms |
| `ms-cxh://WLTUC` | Windows License Terms User Content |

## Notes for IT Administrators

* These protocol handlers can be useful for automation or troubleshooting
* Use with caution as they are undocumented and may change without notice
* Most useful for managing Windows authentication, user accounts, and enterprise settings
* Consider testing in a controlled environment before using in production
