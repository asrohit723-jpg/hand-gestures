"""Run the actions named in config.yaml.

An action is one of:
  {keys: "cmd+shift+]"}            key combo
  {media: play}                    media / volume key
  {shell: "open -a Notes"}         shell command
  {applescript: 'tell app ...'}    AppleScript
  {wait: 0.3}                      pause between steps
  {by_app: [{apps: [...], do: <action>}, ...], default: <action>}
  [<action>, <action>, ...]        steps in order
  "name"                           another action from the actions: table
"""
import subprocess
import time

from . import macos


class Actions:
    def __init__(self, table, dry_run=False, log=print):
        self.table = table
        self.dry_run = dry_run
        self.log = log

    def run(self, action, label=""):
        if isinstance(action, str):
            if action not in self.table:
                self.log(f"unknown action: {action}")
                return
            return self.run(self.table[action], label or action)
        if isinstance(action, list):
            for step in action:
                self.run(step, label)
            return
        if "by_app" in action:
            app = macos.frontmost_app()
            for rule in action["by_app"]:
                if app in rule["apps"]:
                    return self.run(rule["do"], f"{label} in {app}")
            if "default" in action:
                return self.run(action["default"], f"{label} in {app}")
            self.log(f"{label}: nothing set for {app or 'this app'}")
            return
        if "wait" in action:
            if not self.dry_run:
                time.sleep(action["wait"])
            return

        self.log(f"{label}: {action}")
        if self.dry_run:
            return
        if "keys" in action:
            macos.press(action["keys"])
        elif "media" in action:
            macos.media(action["media"])
        elif "shell" in action:
            subprocess.Popen(action["shell"], shell=True)
        elif "applescript" in action:
            subprocess.Popen(["osascript", "-e", action["applescript"]])
        else:
            self.log(f"{label}: don't know how to run {action}")
