# One command: `make -C memory` runs the tests, then starts the service.
.PHONY: all test live serve attest
all: test serve
test:
	uv run pytest -q
live:
	uv run pytest -m live -q
serve:
	uv run pixl-memory serve
attest:
	uv run pixl-memory attest
