#!/usr/bin/env python3
# SensorForge-Test-Sampler: pollt Status-Port 8797 alle 5s, loggt auf stdout.
import socket, time, sys

HOST, PORT = "127.0.0.1", 8797
first = True
while True:
    try:
        s = socket.create_connection((HOST, PORT), timeout=3)
        s.sendall(b"")
        data = s.recv(2048).decode(errors="replace").strip()
        s.close()
        print(f"{time.strftime('%H:%M:%S')} {data}", flush=True)
        first = False
    except Exception as e:
        if first:
            print(f"{time.strftime('%H:%M:%S')} STATUS-PORT UNREACHABLE: {e}", flush=True)
    time.sleep(5)
