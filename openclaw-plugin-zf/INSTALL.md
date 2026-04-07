## copy plugin directory to OpenClaw server

```bash
rsync openclaw-plugin-zf openclaw-server:~/
```

## modif openclaw.json

```json
{
  "plugins": {
    "allow": ["openclaw-plugin-zf"],
    "load": {
      "paths": ["/home/hangil/openclaw-plugin-zf"]
    },
    "entries": {
      "openclaw-plugin-zf": {
        "enabled": true
      }
    }
  }
}
```

## Install

At OpenClaw server,

```bash
cd ~/openclaw-plugin-zf && npm install && npm run build
openclaw gateway restart
```

## Confirm

```bash
openclaw plugins list
```

