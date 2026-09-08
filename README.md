# seb
CodeChef SEB Launch Config

## Windows

- Press Win + R

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://seb.cchef.co/seb.ps1'))) -ContestCode 'SEB'"
```

or 

- Open Powershell

```
& ([scriptblock]::Create((irm 'https://seb.cchef.co/seb.ps1'))) -ContestCode 'SEB'
```

## Mac

```
curl -fsSL https://seb.cchef.co/seb.sh | bash -s -- "SEB"
```


This runs one command that gets your computer ready for a CodeChef exam and opens it for you. You don't need to install anything yourself first — it takes care of that.

## Features Implemented

- Closes any apps that might cause problems during the exam (like remote-access/screen-sharing tools) so the exam browser isn't blocked.
- Closes the exam browser if it happens to already be open, so it can start fresh.
- Checks whether you already have the exam browser installed, and whether it's the latest version.
- Installs the exam browser if you don't have it yet, or updates it if your copy is outdated.
- Makes a few small Windows settings changes so antivirus/proxy don't interfere and the exam browser can run smoothly.
- Resets your mouse pointer back to normal, in case a previous exam changed it.
- Opens the exam browser and takes you straight into your contest — no extra clicking needed.
- Closes the command window it ran from automatically.
- Keeps a log file in the background in case anything needs to be looked into later.
