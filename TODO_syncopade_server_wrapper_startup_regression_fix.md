# Syncopade server wrapper起動回帰の改定 Todo

## 目的

`v0.1.2`で`julia --project=. ./scripts/run_server.jl`を実行すると、serverがlistenせずexit code `0`で即時終了する回帰を修正する。

`syncopadeServer.jl`本体のinclude-safe contractは維持し、実行用wrapperが`main()`を明示的に1回だけ呼ぶ構造へ直す。process生存だけでなく、`192.168.100.30:8030`の`STATUS`応答とconductorからの`idle`観測までをrelease条件にする。

## 原因

- `syncopadeServer.jl`はcommit `13abe8c497353a62d71a3ad1e3c2c37cc1e0ab58`で、直接実行時だけ`main()`を呼ぶinclude-safe構造へ変更された。
- `scripts/run_server.jl`は本体をincludeするだけで、`main()`を呼んでいない。
- wrapper実行時の`PROGRAM_FILE`はwrapper pathなので、本体末尾のguardはfalseとなる。
- その結果、wrapperは定義を読み込んだ後、errorなしで正常終了する。

## 共通制約

- 作業対象はこのrepositoryだけとする。
- `logs/conductor_events.csv`の先生の既存4行差分はstage・commit・復元しない。
- test log、stdout、stderr、receiptはrepository外へ置く。
- 各StepはPhase 1→2→3→4を順に実行し、error時は停止する。
- 各Step完了時にintended pathだけをcommit/pushする。
- 既存tag `v0.1.2`を変更せず、修正版はpatch release `v0.1.3`とする。

---

## Step 1: `v0.1.2`のserver wrapper即時終了を再現し原因を固定する — 完了

### 目的

公式wrapper、server本体、conductor観測を同じlan100環境で比較し、症状・終了状態・原因・副作用を監査可能に固定する。

### 対象ファイル

- このTodo
- `history/TODO_syncopade_conductor_wrapper_startup_regression_fix.md`
- repository外reproduction receipt

### 完了条件

- conductor wrapperが`192.168.100.30:9030`で継続起動する。
- server wrapperがlistenせず正常終了する症状をexit code付きで再現する。
- server本体直接実行が`192.168.100.30:8030`で継続起動する。
- conductorが直接起動serverを`idle`として観測する。
- 原因となるentrypoint guardとwrapper呼出し欠落をsource/commitで対応付ける。
- 全process・8030/9030 listenerをcleanupし、repository log不変を確認する。

### 検証方法

1. lan100で`run_conductor.jl`をterminal起動する。
2. lan100で`run_server.jl`をterminal起動し、exit codeと出力を取得する。
3. lan100で`syncopadeServer.jl`を直接terminal起動する。
4. conductorの`down -> idle -> down`とtemporary logを確認する。
5. process、port、Git差分、repository log identityを照合する。

### Phase 1: 実装方針をまとめる — 完了

- sourceは変更せず、terminal実行とGit履歴から症状と原因を切り分ける。
- conductor logはrepository外へredirectする。
- wrapperと本体直接実行を同じprofile/IP/portで比較する。

### Phase 2: 関数仕様・入出力・副作用をまとめる — 完了

- profile: `lan100`
- conductor wrapper: `192.168.100.30:9030`で継続起動がexpected。
- server wrapper: `192.168.100.30:8030`で継続起動がexpectedだが、現在はexit code `0`で即時終了する。
- server direct entrypoint: `192.168.100.30:8030`で継続起動し、`STATUS|idle`へ応答する。
- cleanup: serverは`q`、conductorはterminal interruptで停止し、両portを解放する。

### Phase 3: 実装する — 完了（source変更なし）

- production/test sourceは変更していない。
- 完了済みconductor wrapper Todoを`history/`へ退避した。
- server wrapper修正用のこのTodoを作成した。

### Phase 4: テストまたは検証を行う — 完了

- `run_conductor.jl`: `192.168.100.30:9030`で継続起動。
- `run_server.jl`: 約0.08秒でexit code `0`、起動表示なし、8030 listenerなし。
- conductor観測: server wrapper実行後も`Chopper 192.168.100.30:8030 => down`。
- `syncopadeServer.jl`直接実行: `192.168.100.30:8030`で継続起動。
- conductor観測: 直接実行中は`Chopper 192.168.100.30:8030 => idle`。
- temporary conductor log: `down -> idle -> down`を記録。
- cleanup後8030/9030 listener: なし。
- remaining Syncopade process: なし。
- repository log content SHA-1: `528443adeeff16bfcd482c552458584d7a080e99`のまま。
- repository log Git blob ID: `b42bd0dc80df7523ceaaf760fa11e8f36fcaac1b`のまま。
- raw evidence/receipt: `/tmp/syncopade-terminal-reproduction.dyO5js/receipt.md`

### Step 1結論

server coreのlisten/runtimeではなく、公式wrapperのentrypoint contract欠落である。commit `13abe8c`で本体をinclude-safeにした際、既存wrapperへ`main()`呼出しを追加しなかったため、wrapperは定義読込後に正常終了する。

---

## Step 2: server wrapperから`main()`を明示呼出ししてcontractを文書化する

### 目的

include-safeなserver本体を維持したまま、公式wrapper直接実行時だけserver runtimeを開始する。

### 対象ファイル

- `scripts/run_server.jl`
- `docs/TESTING.md`
- このTodo

### 完了条件

- wrapperがinclude直後に`main()`を1回呼ぶ。
- server本体の`PROGRAM_FILE` guardを変更しない。
- wrapperをterminal起動すると8030で生存する。
- `q`で正常終了し、portを解放する。

### 検証方法

1. source include checkを行う。
2. lan100でwrapperをterminal起動する。
3. `STATUS`応答とprocess生存を確認する。
4. `q`送信後のexit code、stderr、port解放を確認する。

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 3: server wrapper entrypointの自動回帰testを追加する

### 目的

公式wrapperの継続起動とinclude-onlyの正常終了をprocess-level testで区別し、同じ回帰を自動検出する。

### 対象ファイル

- `test/integration_server_wrapper_entrypoint.jl`
- このTodo

### 完了条件

- positive caseがwrapper childの生存、8030 listen、`STATUS|idle`を確認する。
- child stdinをopenのまま保持し、`q`で正常終了させる。
- negative caseがserver本体include-onlyでexit code `0`、listenerなしとなる。
- bounded cleanupを行い、process/portを残さない。
- repository logへ書き込まない。

### 検証方法

1. test harness include-onlyが副作用なく終了することを確認する。
2. 8030 preflight後にpositive/negative caseを実行する。
3. response、exit code、signal、stdout/stderr、cleanupを検証する。
4. test単体を再実行して再現性を確認する。

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 4: conductorとserverの両wrapperを使ったrelease前回帰を行う

### 目的

unitだけでなく実wrapper 2本を同時起動し、serverがconductorへ`idle` nodeとして現れることをrelease前に確認する。

### 対象ファイル

- このTodo
- repository外test artifacts/receipt

### 完了条件

- 既存unit、server admission、conductor wrapper、server wrapper testが全てpassする。
- 両wrapper同時起動時にconductor `LIST`が`192.168.100.30:8030`を返す。
- 全stderr、exit status、port cleanup、repository log不変を確認する。

### 検証方法

1. standard unitとserver admission unitを実行する。
2. conductor/server wrapperの個別integrationを実行する。
3. 両wrapperを同時起動し、`LIST`応答を検証する。
4. 8030/9030、process、log identity、Git差分を照合する。

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手

---

## Step 5: patch release `v0.1.3`を作成する

### 目的

server wrapper startup回帰修正を、既存tagを変更せず新しいpatch releaseとして固定する。

### 対象ファイル

- `Project.toml`
- このTodo
- Git commit / annotated tag / remote refs

### 完了条件

- `Project.toml`がversion `0.1.3`となる。
- version変更後にもStep 4相当の全回帰がpassする。
- release commitがremote `master`へpushされる。
- annotated tag `v0.1.3`がrelease commitを指す。
- local/remote master、tag、peeled targetが一致する。
- `v0.1.2`以前のtag targetを変更しない。
- repository logをstage・commitしない。

### 検証方法

1. `Pkg.project().version == v"0.1.3"`を確認する。
2. Step 4相当の全回帰を再実行する。
3. intended pathだけをstageしてrelease commitをpushする。
4. annotated tagを作成・pushし、local/remote refsを照合する。

### Phase 1: 実装方針をまとめる — 未着手

### Phase 2: 関数仕様・入出力・副作用をまとめる — 未着手

### Phase 3: 実装する — 未着手

### Phase 4: テストまたは検証を行う — 未着手
