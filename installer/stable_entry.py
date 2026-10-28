"""Compatibility marker for installer verifiers released before 1.2.92.

Those verifiers require this filename in the signed helper cohort even though
the standalone TCP-entry feature and its installer command have been removed.
There is deliberately no service configuration or execution implementation.
"""

if __name__ == '__main__':
    raise SystemExit('The standalone TCP-entry feature has been removed')
