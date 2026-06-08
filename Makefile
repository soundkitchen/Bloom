# Bloom 開発用ショートカット
# DerivedData はリポジトリ(Dropbox 配下)の外に置く: 同期のノイズ・競合を避けるため
DERIVED := $(HOME)/Library/Developer/Xcode/DerivedData/Bloom-cli
APP     := $(DERIVED)/Build/Products/Debug/BloomApp.app/Contents/MacOS/BloomApp
# -allowProvisioningUpdates: 自動署名が開発用プロビジョニングプロファイルを取得/更新できるようにする
XCB     := xcodebuild -project Bloom.xcodeproj -scheme BloomApp -configuration Debug -derivedDataPath $(DERIVED) -allowProvisioningUpdates

.PHONY: gen build test run demo clean

gen: ## project.yml から Bloom.xcodeproj を生成
	xcodegen generate

build: gen
	$(XCB) build

test: gen
	$(XCB) test

run: build ## アプリを起動(ドラッグで描く / c: クリア / d: デモ)
	$(APP)

demo: build ## デモストロークを自動実行し wet/dry PNG を書き出す
	$(APP) --demo --snapshot-dir /tmp/bloom-snap
	@echo "snapshots: /tmp/bloom-snap/wet.png /tmp/bloom-snap/dry.png"

clean:
	rm -rf $(DERIVED)
