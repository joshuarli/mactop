PREFIX    ?= $(HOME)/.local
BIN        = mactop
LABEL      = com.mactop
AGENT_DIR  = $(HOME)/Library/LaunchAgents
PLIST      = $(AGENT_DIR)/$(LABEL).plist

.PHONY: build install uninstall clean

dev: build
	.build/debug/mactop

build:
	swift build
	codesign -fs - .build/debug/$(BIN)
	xattr -d com.apple.quarantine $(PWD)/.build/debug/$(BIN) 2>/dev/null || true

install:
	swift build -c release
	install -d $(PREFIX)/bin
	install -m 755 .build/release/$(BIN) $(PREFIX)/bin/$(BIN)
	codesign -fs - $(PREFIX)/bin/$(BIN)
	xattr -d com.apple.quarantine $(PREFIX)/bin/$(BIN) 2>/dev/null || true
	install -d $(AGENT_DIR)
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"' \
	  '  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0">' \
	  '<dict>' \
	  '  <key>Label</key>' \
	  '  <string>$(LABEL)</string>' \
	  '  <key>ProgramArguments</key>' \
	  '  <array>' \
	  '    <string>$(PREFIX)/bin/$(BIN)</string>' \
	  '  </array>' \
	  '  <key>RunAtLoad</key>' \
	  '  <true/>' \
	  '</dict>' \
	  '</plist>' > $(PLIST)
	launchctl bootout gui/$$(id -u) $(PLIST) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(PLIST)
	launchctl kickstart -k gui/$$(id -u)/$(LABEL)

uninstall:
	launchctl bootout gui/$$(id -u) $(PLIST) 2>/dev/null || true
	rm -f $(PREFIX)/bin/$(BIN) $(PLIST)

clean:
	swift package clean
