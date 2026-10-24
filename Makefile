# Omamich — build the backend and install the plugin for development.
CARGO ?= cargo
BIN := bin/omamich

.PHONY: build install link test test-rust test-sync test-library test-ui lint clean

build:
	$(CARGO) build --release --locked

# The plugin runs bin/omamich from its own folder.
install: build
	mkdir -p bin
	install -m 755 target/release/omamich $(BIN)

# Point Omarchy at this checkout and enable the plugin (bar widget, service, window).
link: install
	./scripts/link-plugin.sh

test: test-rust test-sync test-library test-ui lint

test-rust:
	$(CARGO) test --locked

test-sync:
	$(CARGO) build --locked
	python3 -I tests/sync_e2e.py target/debug/omamich

lint:
	@for f in $$(find ui -name '*.qml'); do /usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml $$f >/dev/null 2>&1 || true; done
	@node --version >/dev/null 2>&1 && node tests/ui_logic.js || echo "node not found; skipping UI logic tests"

clean:
	rm -rf target bin

test-library:
	$(CARGO) build --locked
	python3 tests/library_e2e.py target/debug/omamich

# Drives the real window off-screen (QT_QPA_PLATFORM=offscreen) against the
# seeded mock. Set OMAMICH_UI_SHOTS=/some/dir to keep the screenshots.
test-ui:
	$(CARGO) build --locked
	python3 tests/ui_e2e.py target/debug/omamich
