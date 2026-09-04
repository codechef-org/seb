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
