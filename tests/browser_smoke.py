"""Optional real Chromium end-to-end check. Uses temporary files and simulated UARTs.

Run: .venv/bin/python -m tests.browser_smoke
Requires: pip install playwright; python -m playwright install chromium
"""
from __future__ import annotations

import socket
import tempfile
import threading
import time
from pathlib import Path

import httpx
import uvicorn
from playwright.sync_api import sync_playwright, expect

from radar_app.api import ROOT, create_app
from radar_app.serial_service import RadarService
from radar_app.simulation import SimulatedTransport


def main():
    transport = SimulatedTransport()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        def factory(store):
            service = RadarService(store, transport)
            service.ports = lambda: [dict(device="sim-command", description="Simulated command UART", serial_number="test"), dict(device="sim-data", description="Simulated data UART", serial_number="test")]
            return service
        app = create_app(root, factory)
        cfg = (ROOT / 'radar_analyzer/example_input/profile.cfg').read_text()
        data = (ROOT / 'radar_analyzer/example_input/recording.dat').read_bytes()
        (root / 'configs/test.cfg').write_text(cfg)
        (root / 'logs/source.dat').write_bytes(data)
        (root / 'logs/matching.cfg').write_text(cfg)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(app, host='127.0.0.1', port=port, log_level='warning'))
        thread = threading.Thread(target=server.run, daemon=True)
        thread.start()
        url = f'http://127.0.0.1:{port}'
        for _ in range(100):
            try:
                if httpx.get(url+'/api/status').status_code==200:break
            except httpx.ConnectError:pass
            time.sleep(.05)
        errors=[]
        try:
            with sync_playwright() as p:
                browser=p.chromium.launch(headless=True)
                page=browser.new_page(viewport={"width":1440,"height":1000})
                page.on('pageerror',lambda exc:errors.append(str(exc)))
                page.goto(url)
                page.locator('#commandPort').select_option('sim-command')
                page.locator('#dataPort').select_option('sim-data')
                page.locator('#connect').click()
                expect(page.locator('#states')).to_contain_text('connected/state unknown')
                page.locator('#configList').select_option('test.cfg')
                page.locator('#loadConfig').click()
                expect(page.locator('#configSummary')).to_contain_text('256 samples')
                page.locator('#apply').click()
                expect(page.locator('#states')).to_contain_text('measuring',timeout=15000)
                page.locator('[data-tab=live]').click()
                page.locator('#recordStart').click()
                expect(page.locator('#states')).to_contain_text('RECORDING')
                for pos in range(0,len(data),251):transport.data.feed(data[pos:pos+251])
                expect(page.locator('#recordHealth')).to_contain_text('143 detections',timeout=10000)
                frame=page.frame_locator('#viewer')
                expect(frame.locator('#points')).to_have_text('143')
                page.reload()
                expect(page.locator('#states')).to_contain_text('RECORDING')
                page.locator('[data-tab=live]').click()
                page.locator('#recordStop').click()
                expect(page.locator('#states')).to_contain_text('Not recording')
                page.locator('[data-tab=sessions]').click()
                page.get_by_role('button',name='Open / edit').first.click()
                frame=page.frame_locator('#viewer')
                expect(frame.locator('#frames')).to_have_text('500')
                frame.locator('#fastest').click()
                expect(frame.locator('#frameInfo')).to_contain_text('3.160 s')
                frame.locator('#markImpact').click()
                frame.locator('#intervalStart').click()
                frame.locator('#to').fill('4')
                frame.locator('#to').dispatch_event('change')
                for t in ('3.16','3.18','3.2','3.22'):
                    frame.locator('#seekSeconds').fill(t)
                    frame.locator('#seekAt').click()
                    expect(frame.locator('#frameInfo')).to_contain_text(f'{float(t):.3f} s')
                    frame.locator('#rows tr').first.click()
                    frame.locator('#addCandidate').click()
                expect(frame.locator('#annotationStatus')).to_contain_text('4 manually selected')
                frame.locator('#analyzeInterval').click()
                expect(frame.locator('#analysisResult')).to_contain_text('Estimated mean 3D velocity')
                frame.locator('#saveAnnotations').click()
                expect(frame.locator('#annotationStatus')).to_contain_text('Annotations saved')
                frame.locator('#clearCandidates').click()
                frame.locator('#reloadAnnotations').click()
                expect(frame.locator('#annotationStatus')).to_contain_text('4 manually selected')
                with page.expect_download() as download:
                    frame.locator('#manualCSV').click()
                assert len(Path(download.value.path()).read_text().strip().splitlines())==5
                frame.locator('#play').click()
                expect(frame.locator('#play')).to_have_text('Pause')
                frame.locator('#play').click()
                page.locator('#editLabel').fill('Browser verified shot')
                page.locator('#saveDetails').click()
                expect(page.locator('#replayTitle')).to_have_text('Browser verified shot')
                with page.expect_download() as download:page.locator('#bundle').click()
                assert Path(download.value.path()).stat().st_size>0
                page.locator('[data-tab=sessions]').click()
                page.locator('#importDat').select_option('source.dat')
                page.locator('#importCfg').select_option('matching.cfg')
                page.locator('#importLabel').fill('Explicit browser import')
                page.locator('#importPair').click()
                expect(page.locator('#replayMode')).to_contain_text('user-supplied')
                page.locator('#disconnect').is_visible() # available on connection tab
                page.locator('[data-tab=radar]').click()
                page.locator('#disconnect').click()
                expect(page.locator('#states')).to_contain_text('disconnected')
                page.locator('#demo').click()
                expect(page.locator('#replayMode')).to_contain_text('Hardware DISCONNECTED')
                expect(page.frame_locator('#viewer').locator('#points')).to_have_text('143')
                page.screenshot(path='/tmp/opencode/radar-workbench.png',full_page=True)
                assert not errors, errors
                browser.close()
                print('PASS: real Chromium connect/apply/live/record/reopen/stop/replay/manual fit/annotations/CSV/ZIP/import/demo; no browser JavaScript errors.')
        finally:
            server.should_exit=True
            thread.join(timeout=10)


if __name__=='__main__':main()
