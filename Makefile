.PHONY: build release app run stop clean

build:
	swift build

release:
	swift build -c release

app: release
	./Scripts/build_app.sh

run: app
	open .build/Tokenomics.app

stop:
	-pkill -x Tokenomics

clean:
	rm -rf .build
