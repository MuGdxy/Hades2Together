"""Drive four standard player terminals from their own complete authority snapshots."""

import argparse
import math
from pathlib import Path
import re
import subprocess
import time


def fields(line):
    return dict(re.findall(r"(\w+)=([^\s]+)", line))


def status_block(report):
    blocks = re.findall(r"control=play\r?\n(.*?)observerStatus=complete", report, re.S)
    if not blocks:
        return
    rows = blocks[-1].splitlines()
    tick = next((int(row[5:]) for row in rows if row.startswith("tick=")), None)
    if tick is None:
        return
    return tick, [(row.split(" ", 1)[0], fields(row)) for row in rows]


def position(actor):
    return float(actor["x"]), float(actor["y"])


def alive(actor):
    return float(actor["hp"].split("/")[0]) > 0


class Player:
    def __init__(self, root, name):
        self.name = name
        self.path = root / (name + "-terminal.txt")
        self.output = self.path.open("xb")
        self.proc = subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             root / "clients" / name / "player.ps1"],
            stdin=subprocess.PIPE, stdout=self.output, stderr=subprocess.STDOUT, text=True)
        self.seat = None
        self.tick = -1
        self.release_at = None
        self.next_input = 0
        self.choices = set()
        self.used = set()
        self.stopping_at_drop = None
        self.complete = False

    def send(self, line):
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()
        if line != "status":
            print(time.time(), self.name, self.seat, line, flush=True)

    def pulse(self, line, now, duration):
        self.send(line)
        self.release_at = now + duration

    def update(self, now, room_id):
        if self.proc.poll() is not None:
            raise RuntimeError(f"{self.name} exited {self.proc.returncode}: see {self.path}")
        if self.release_at is not None and now >= self.release_at:
            self.send("input 0 0")
            self.release_at = None
            self.next_input = now + 0.12
        with self.path.open("rb") as stream:
            stream.seek(max(0, stream.seek(0, 2) - 32768))
            report = stream.read().decode("utf-8", "replace")
        if self.seat is None:
            welcome = re.search(r"joined name=\S+ seat=(\d+)", report)
            if not welcome:
                return
            self.seat = int(welcome[1])
            print(self.name, "welcome", self.seat, flush=True)
        sample = status_block(report)
        if not sample or sample[0] <= self.tick or self.release_at is not None or now < self.next_input:
            return
        self.tick, rows = sample
        room = next((a for label, a in rows if label.startswith("room=")), {})
        if room.get("id") != room_id or room.get("leaving") != "false":
            raise RuntimeError(f"{self.name} tick {self.tick}: original room ended {room}")
        heroes = {int(a["seat"]): a for label, a in rows if label == "hero" and "seat" in a}
        hero = heroes.get(self.seat)
        claims = [a for label, a in rows if label == "claim" and a["kind"] == "PoseidonUpgrade"]
        for claim in claims:
            if int(claim["seat"]) != self.seat:
                continue
            if claim["state"] == "consumed":
                self.complete = True
                return
            opportunity = claim.get("opportunity")
            if opportunity and claim.get("grantOption") and opportunity not in self.choices:
                self.send(f"boon {opportunity} {claim['grantOption']}")
                self.choices.add(opportunity)
                return
        if set(heroes) != {1, 2, 3, 4} or not hero or not alive(hero):
            return
        x, y = position(hero)
        drop = next((a for label, a in rows if label == "reward" and a.get("objectId")
                     and a["kind"] == "PoseidonUpgrade"), None)
        if drop:
            if self.seat != 1 or self.choices:
                return
            key = (room_id, drop["id"], drop["objectId"])
            if key in self.used:
                return
            if drop.get("hostUseTarget") == "true":
                if self.stopping_at_drop != key:
                    self.send("input 0 0")
                    self.stopping_at_drop = key
                    self.next_input = now + 0.12
                else:
                    self.pulse("input 0 0 Use", now, 0.15)
                    self.used.add(key)
                return
            self.stopping_at_drop = None
            if "x" not in drop or "hostUseTarget" not in drop:
                raise RuntimeError(f"drop {key} lacks stock location or Use target readback")
            dest = position(drop)
        else:
            enemies = [a for label, a in rows if label == "enemy" and "x" in a and alive(a)]
            if not enemies:
                return
            target = min(enemies, key=lambda a: math.dist((x, y), position(a)))
            dest = position(target)
        dx, dy = dest[0] - x, dest[1] - y
        distance = math.hypot(dx, dy)
        # Keep a direction for stock facing at attack range. The engine resolves the hit.
        attack = not drop and distance < 310
        strength = min(1.0, max(0.35, distance / 150))
        line = f"input {strength * dx / max(1, distance):.3f} {strength * dy / max(1, distance):.3f}"
        self.pulse(line + (" Attack2" if attack else ""), now, 0.15 if attack else 0.26)

    def close(self):
        try:
            if self.proc.poll() is None:
                self.send("input 0 0")
                self.send("quit")
                self.proc.wait(5)
        finally:
            self.proc.stdin.close()
            self.output.close()


def operate(root):
    marker = root / "room-ready.txt"
    deadline = time.monotonic() + 90
    while not marker.is_file():
        if time.monotonic() >= deadline:
            raise RuntimeError("observer received no complete opening room snapshot")
        time.sleep(0.05)
    ready = fields(marker.read_text())
    print("first complete snapshot", ready, flush=True)
    players = []
    try:
        for name in ("PlayerA", "PlayerB", "PlayerC", "PlayerD"):
            players.append(Player(root, name))
        poll_at = 0
        while not (root / "stop-players.txt").exists():
            now = time.monotonic()
            for player in players:
                if now >= poll_at:
                    player.send("status")
                player.update(now, ready["id"])
            if all(player.complete for player in players):
                print("all four players observed their consumed claim", flush=True)
                return
            if now >= poll_at:
                poll_at = now + 0.13
            time.sleep(0.035)
    finally:
        for player in players:
            player.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_root", type=Path)
    operate(parser.parse_args().run_root.resolve())
