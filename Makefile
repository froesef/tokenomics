.PHONY: build release app run stop clean

build:
	swift build

release:
	swift build -c release

app: release
	./Scripts/build_app.sh

run: stop app
	open .build/Tokenomics.app

stop:
	-pkill -x Tokenomics
	@while pgrep -x Tokenomics >/dev/null; do sleep 0.1; done

clean:
	rm -rf .build
