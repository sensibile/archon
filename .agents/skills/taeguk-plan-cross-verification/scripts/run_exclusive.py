#!/usr/bin/env python3
"""Run one foreground command under a cooperative Unix resource lock."""
import argparse
import fcntl
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys

FORWARDED_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM)


def make_private_dirs(directory):
    """Create missing lock directories as owner-only; call under umask 077.

    A directory other accounts can write would let them pre-create the lock.
    Existing directories are left alone: a shared group directory is the
    administrator's choice.
    """
    missing = []
    for path in (directory, *directory.parents):
        if path.exists():
            break
        missing.append(path)
    for path in reversed(missing):
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', required=True, type=Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ['--']:
        command = command[1:]
    if not command:
        parser.error('a foreground command is required after --')
    # A fixed umask makes the 0700 directories and 0600 lock exact at creation,
    # with no chmod window and no owner bits lost. The command keeps the caller's umask.
    umask = os.umask(0o077)
    try:
        make_private_dirs(args.lock.parent)
        # Keep the inode: deleting a lock file can permit a second independent lock.
        fd = os.open(args.lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError as error:
        print(f'lock could not open: {error.strerror}', file=sys.stderr)
        return 2
    finally:
        os.umask(umask)
    with os.fdopen(fd, 'a') as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            print('lock must be a regular file', file=sys.stderr)
            return 2
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('resource busy; command was not started', file=sys.stderr)
            return 75
        # Install handlers before spawning so no signal can kill the wrapper
        # between Popen and forwarding, leaving a detached child on the lease.
        state = {'child': None, 'pending': []}

        def forward(signum, _frame):
            if state['child'] is None:
                state['pending'].append(signum)
                return
            try:
                os.killpg(state['child'].pid, signum)
            except ProcessLookupError:
                pass

        # Block while installing so a signal cannot hit a not-yet-installed
        # default handler; it is delivered to `forward` once the mask is restored.
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, FORWARDED_SIGNALS)
        try:
            previous = {sig: signal.signal(sig, forward) for sig in FORWARDED_SIGNALS}
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        try:
            if state['pending']:
                print('interrupted; command was not started', file=sys.stderr)
                return 128 + state['pending'][0]
            try:
                # The child retains the lease if this wrapper is abruptly killed.
                state['child'] = child = subprocess.Popen(command, pass_fds=(lock.fileno(),), start_new_session=True)
            except OSError as error:
                print(f'command could not start: {error.strerror}', file=sys.stderr)
                if state['pending']:
                    # A stop request that already arrived outranks the start failure.
                    print('interrupted; command was not started', file=sys.stderr)
                    return 128 + state['pending'][0]
                return 127
            for signum in state['pending']:
                forward(signum, None)
            print(f'exclusive command started: pid={child.pid}', file=sys.stderr, flush=True)
            code = child.wait()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        return code if code >= 0 else 128 - code


if __name__ == '__main__':
    sys.exit(main())
