# Todo: KIX・FIVES・JESSE・REXを両LANのノード一覧へ追加

## 状態と進め方

- 2026-09-30作成。先生が指定した4台・2系統のIPと、既存のport規則を反映した確認用Todo。
- 2026-09-30、先生の「強化C進行で進めようか」によりTodoの相互確認と全3 Stepの開始を承認。
  Todo作成・確認はStep 1／Phase 1とは別。承認したTodoを先にcommit/pushし、Step 1から順に実行する。
- 先生より新4台はM4 Mac miniとの申告があり、既存nodeより優先して使用する希望を確認した。
  優先方針の確認後、上記の別指示で実行を開始する。
- 進行方式: 強化C。各StepのPhase 1→2→3→4を順に実施・記録し、Stepごとの追加指示を待たず進める。
  灯子の誤字・単純な実装ミスは修正して同じ検証をやり直す。前提変更・Todo見直しが必要なら停止する。
- 現在: 全3 Stepの実装・検証完了。Step 1は`74a0751`、Step 2は`351e5ae`でcommit/push済み。
  Step 3の結果は末尾に記録。実LANへの反映・実機通信試験、version/tag更新、Todo退避は実施していない。
- 実行開始後は完了Stepごとに、検証済みの対象ファイルだけをcommit/pushする。
- 作成時HEAD: `bf37c9b3dcdb2f10f61df817f22f404af61783e0`（`master`、package version `0.1.5`）。
- トップに既存Todoはなく、過去の完了Todoは`history/`へ退避済み。今回移動する既存Todoはない。
- 既存差分は`logs/conductor_events.csv`の4行追加のみ。変更・stage・commitしない。
  SHA-256: `20f0129709ac36e64ec0191878ee18be2cc247104e74a5b54d46aedc305dbef0`。

## 確定した追加内容

portは既存規則 `8000 + IPv4アドレスの末尾` に従う。

| 名前 | lan12 IP | port | lan100 IP | port |
|---|---|---:|---|---:|
| KIX | 192.168.12.15 | 8015 | 192.168.100.107 | 8107 |
| FIVES | 192.168.12.16 | 8016 | 192.168.100.105 | 8105 |
| JESSE | 192.168.12.17 | 8017 | 192.168.100.106 | 8106 |
| REX | 192.168.12.18 | 8018 | 192.168.100.104 | 8104 |

- 正本は先生の上記指定。名前の大文字・IP対応をそのまま保持する。
- `lan12`と`lan100`へ各4件追加し、各profileを12件から16件へ増やす。32台の物理PCとは数えない。
- 両profileとも既存12件を並べ替えず、末尾へ先生の列挙順 `KIX → FIVES → JESSE → REX` で追加する。
  conductorの既存仕様は末尾から空きnodeを選ぶため、新4台の優先順は `REX → JESSE → FIVES → KIX` となる。
  新4台を既存nodeより優先する方針は先生と確認済み。4台内の順序はこの案を維持する。
  新4台に使用可能なidle nodeがなければ既存nodeも使う。M4が空くまで既存nodeを待機させる方式にはしない。
  CPU性能の自動測定・重み付け・実行中taskの移動は追加せず、既存の末尾優先という仕様を利用する。
- 既定profileは`lan12`のまま。指定されていないIPを追加せず、既存nodeの名前・IP・portを変更しない。

## 範囲と運用上の境界

- 製品側の変更は`syncopadeNodeConfig.jl`のデータ追記だけ。conductor/server本体や通信仕様は変えない。
- conductorは起動時に設定を読み込み、監視対象一覧を作る。起動中の一覧の自動再読込みは追加しない。
- 実環境への反映時は投入を止め、待機中・実行中・成否不明の仕事や管理操作が残っていないことを確認してから
  conductorを再起動する。メモリ上のqueueやtask状態を再起動で引き継げるとは扱わない。
- 新4台のserver起動、共有フォルダ・利用packageの準備、実通信・計算確認は実環境側の作業。
  このTodoでは実LAN上のserver/conductorの起動・停止・接続・cache clear・計算投入は行わない。
- 既存serverは一覧追記だけのために再起動しない。新serverを引数なしで起動する場合は、
  そのPCでも更新した一覧と対象profileを使い、起動表示のIP・portを確認する。
- 対象一覧の`SYNCOPADE_NODE_PROFILE`と、conductor自身のIPを選ぶ`SYNCOPADE_WIRED_PREFIX`は別設定。
  lan100を使う場合はそれぞれ`lan100`・`192.168.100.`を確認する。clientの結果受信経路も別途必要。
- `LIST`は登録全件ではなく使用可能なidle nodeだけを返す。一斉再起動・cache clearは追加nodeも対象になる。
- 他リポジトリ・実ノードを変更しない。version更新・tag作成は今回の範囲に含めない。

## Step 1: lan12へ4台を追加する

- **目的:** 先生が指定した192.168.12側の4台だけを正確に登録する。
- **対象ファイル:** `syncopadeNodeConfig.jl`、本Todo。
- **実装方針案:** `lan12`の末尾へ4件追記し、`lan100`と既存12件は変更しない。
- **関数・入出力・副作用案:** 新規関数なし。`configured_node_entries(profile="lan12")`の返す一覧が
  16件になる。項目の型・順序の契約・環境変数による選択・既定profileは維持する。
- **完了条件:** lan12が16件、lan100は12件。新4件が表の指定と完全一致し、既存内容と順序が不変。
- **検証方法:** 独立Juliaで設定ファイルだけをincludeし、件数・名前/IP/portの対応・port規則・endpoint重複なしを
  assertionで確認する。作成時commitとの比較で既存一覧の不変を確認する。socketを開かず、LANへ接続しない。
  `git diff --check`、対象外差分なし、既存log hash不変を確認して対象のみcommit/pushする。
- [x] Phase 1 — 実装方針と確認メモを確定
  - 承認済みTodoを`4a360d0`でcommit/push。作成時HEAD・remote一致と既存log hashを確認した。
  - 変更箇所はlan12配列の末尾4行に限定する。既存12件を維持し、KIX/FIVES/JESSE/REXの順に追記する。
    lan100は次Stepまで変更しない。読み込み試験だけを使い、実LANへ接続しない。
- [x] Phase 2 — 設定の入出力・変更範囲・検証仕様を確定
  - 入力`profile="lan12"`に対する一覧の末尾が、指定4台の`(ip::String, port::Int, name::String)`になる。
    既定値、未知profileの例外、関数本体・副作用は不変。lan100の出力も不変。
  - 独立Juliaで現行設定と作成時commitの設定を別moduleに読み込み、先頭12件・lan100全件を比較する。
    追加4件は先生の指定を独立した期待値として照合し、IP形式・port規則・endpoint/name重複も検査する。
- [x] Phase 3 — lan12へ4件追記
  - 指定されたIP・port・大文字の名前で4行を追加。関数・既定値・既存の行は変更していない。
- [x] Phase 4 — 独立検証・差分確認・記録・commit/push
  - `julia --startup-file=no --project=. -e ...`による独立設定比較は67/67、exit 0。
    lan12は16件・指定4件一致、既存12件とlan100全件は作成時commitと一致した。
    全28件のIPv4・port規則・重複なし、既定値不変、既存log hash不変も確認した。
  - `git diff --check`合格。製品差分はlan12末尾4行だけ。本Todoと設定ファイルだけをcommit/pushする。

## Step 2: lan100へ同じ4台を追加する

- **目的:** 同じ4台の192.168.100側のアドレスを取り違えずに登録する。
- **対象ファイル:** `syncopadeNodeConfig.jl`、本Todo。
- **実装方針案:** lan100の末尾にも先生の列挙順で4件追記する。
  lan100側はIP末尾が107・105・106・104なので、lan12から連番を推測して書かない。
- **関数・入出力・副作用案:** 新規関数なし。`configured_node_entries(profile="lan100")`の返す一覧が
  16件になる。Step 1で確定したlan12の16件は変更しない。
- **完了条件:** 両profileが各16件。追加nodeの名前が両LANで対応し、各IPとportが指定表に一致する。
- **検証方法:** 設定のみを読む独立Juliaで全対応・件数・port規則・endpoint重複なしを検証する。
  作成時commitの既存12件とStep 1のlan12一覧を比較し、不変を確認する。
  `git diff --check`、既存log hash不変を確認して対象のみcommit/pushする。
- [x] Phase 1 — 実装方針とIP対応の確認メモを確定
  - Step 1は`74a0751`でcommit/push済み。次はlan100だけを変更する。
  - KIX=107、FIVES=105、JESSE=106、REX=104を指定表から個別に照合し、列挙順で末尾に追記する。
    lan12の16件とlan100の既存12件は保持する。
- [x] Phase 2 — 設定の入出力・変更範囲・検証仕様を確定
  - 入力`profile="lan100"`に対する一覧だけを16件へ拡張。追加4件のportは順に8107/8105/8106/8104。
    関数・既定値・profile選択の仕組みは不変。
  - 作成時commitとの先頭12件比較に加え、Step 1 commitから読み込んだlan12全16件との比較を行う。
    新4台の名前の順序が両LANで一致し、各IP・portが独立した指定期待値と一致することを検査する。
- [x] Phase 3 — lan100へ4件追記
  - 指定表の4行を末尾に追加。既存lan100の12件とlan12の16件、関数定義は変更していない。
- [x] Phase 4 — 両LANの対応検証・差分確認・記録・commit/push
  - `julia --startup-file=no --project=. -e ...`による独立設定比較は76/76、exit 0。
    両profile各16件、指定8 endpoint、両LANの新4台の名前順一致を確認した。
    lan12全件はStep 1 commitと一致、両profileの先頭12件は作成時commitと一致。
    全32件のIPv4・port規則・重複なし、既定値不変、既存log hash不変も確認した。
  - `git diff --check`合格。製品差分はlan100末尾4行だけ。本Todoと設定ファイルだけをcommit/pushする。

## Step 3: 読込みの回帰試験と反映手順を残す

- **目的:** 登録内容の取り違えを継続検査できるようにし、conductorへの反映方法を明記する。
- **対象ファイル:** `test/unit_node_config.jl`（新規）、`test/runtests.jl`、`docs/TESTING.md`、本Todo。
- **実装方針案:** 通信しない設定の回帰試験を追加し、既存の独立process方式のsuiteへ登録する。
  conductorの読み込みは新しいJuliaで定義のみをincludeし、`geneAvailableNodeList()`で確認する。
  `main()`・監視・サーバ待受けは呼ばず、実ノードの稼働確認と混同しない。
- **関数・入出力・副作用案:** 製品関数の変更なし。試験はprofile選択、既定値、登録件数・指定された8 endpoint、
  重複なし・追記順を検査する。試験中に変更する環境変数はスコープを限定して復元する。
  conductor読込みの確認では16件のIP・port・nameが設定一覧と一致することを両profileで検査する。
- **完了条件:** 新規設定試験とconductor読込み確認が成功し、全36-file suiteがexit 0。
  両profileで新4台が既存12件より優先される配置になっていることも確認する。
  文書に追加4台、profile/IP選択の区別、conductor再起動が必要なこと、実機確認の未実施範囲を明記する。
- **検証方法:** 新規試験の単独実行、conductor定義の読込み確認、
  `julia --startup-file=no --project=. --threads=4 test/runtests.jl`。
  suiteの通信は既存のloopback一時fixtureのみ。子processのexit/stderrと後始末まで確認し、
  文書リンク・`git diff --check`・既存log hashも検証する。実測結果を記録して対象のみcommit/pushする。
- [x] Phase 1 — 回帰試験・文書化の方針を確定
  - Step 2は`351e5ae`でcommit/push済み。製品差分は両配列への合計8行だけ。
  - 新規試験は設定の期待値とconductorが作る候補一覧を照合し、M4優先と既存nodeへの割当て継続も
    メモリ内の模擬idle状態で検証する。実LANへのprobe・main・監視・待受け・task配送は呼ばない。
  - 文書には指定された8 endpoint、末尾優先、profileと自身の通信IPの区別、反映時の安全な再起動手順を記す。
    既存の35-file suiteを36-fileへ拡張し、過去の検証件数は当時の記録として保持する。
- [x] Phase 2 — 試験の入力・期待値・副作用と文書項目を確定
  - `unit_node_config.jl`はconductorの定義だけをincludeし、既存12件と新4件の独立した期待配列を持つ。
    両profile各16件・指定値・順序、IPv4/port、名前/endpoint重複、既定/未知profile、環境変数選択を検査する。
  - `geneAvailableNodeList()`の16要素を設定と照合する。模擬状態を全件idleにして、実際の予約関数
    `reserve_idle_node_right_to_left!`を順番に呼び、REX/JESSE/FIVES/KIX→既存12件の逆順で予約され、
    全件予約済みなら追加予約がないことを確認する。task自体は投入・配送しない。
  - 副作用は試験process内のnode状態と専用一時directoryの予約logだけ。`withenv`で環境変数を復元し、
    finallyで状態を消去・log writerを停止して一時directoryを回収する。製品関数は変更しない。
  - suiteのexit/stderr判定は変更せず、新規1 fileを追加する。文書は現行36 fileと設定の運用を更新し、
    過去の35-file検証記録は書き換えない。設定の反映と実ノードの通信・計算確認を明確に分ける。
- [x] Phase 3 — 試験追加・suite登録・文書追記
  - `unit_node_config.jl`を追加し、36-file suiteへ登録した。期待値は既存24件・追加8件を明記し、
    conductorの実予約関数で新4台優先と既存nodeへの継続割当てを検査する。実LANへの通信は行わない。
  - `docs/TESTING.md`に両profile各16件、追加先一覧、優先順、二系統LANの選択と反映手順を記載した。
    過去の検証記録とsuiteのexit/stderr検査は維持した。
- [x] Phase 4 — 個別確認・全体試験・記録・commit/push
  - 単独の`julia --startup-file=no --project=. --threads=4 test/unit_node_config.jl`は237/237、exit 0。
    両profileの16件をconductorがそのまま読み、REX/JESSE/FIVES/KIX→D-O以降の既存nodeの順で
    予約することを確認した。専用logの停止・一時directory回収・環境変数復元も合格。
  - suite登録36件・重複なし・全file存在、文書内8 endpoint、構文・末尾改行・相対link・既存log hashの
    整合確認は25/25、exit 0。`git diff --check`も合格。
  - `julia --startup-file=no --project=. --threads=4 test/runtests.jl`はexit 0、4m43.3s。
    全36 file、子2794/2794・親72/72、合計2866/2866。全子のstderrは空。
    新規設定237、既存試験2557（操作競合100）、終了処理607を含む全件を検証した。
    競合試験の件数は実行により変動するため、今回の実測として記録する。
  - 記録された所有PID 99件の残留なし、一時suite directory回収済み。既存fixtureのport再利用検査も合格。
    最終のwrapper/4 threads/busy/group SIGINTは親45544・子45545・port58868で正常に後始末された。
    実行環境はJulia 1.12.3、macOS/Darwin、aarch64。実LANと新4台の実機には接続していない。
  - 既存log SHA-256不変。Step 3の対象は本Todo、TESTING、runtests、新規unit_node_configの4ファイルのみ。
    検証済みのこの4ファイルをcommit/pushする。製品側は両profile末尾への8行追記だけで、
    conductor/serverの関数・version・tagは変更していない。

## 今回の完了判定

- 両profileへの指定どおりの追記と、ローカルでの設定読込み・回帰試験までを完了範囲とする。
- 新4台が実際に通信・計算できることは、実ノードで別途確認するまで未確認と報告する。
- 前提変更やStep追加が必要なら、局所的に継ぎ足さずTodo全体の見直しを先生に提案して止まる。
- 2026-09-30の相互確認・開始指示に基づき、全3 Stepを順番に実行・検証した。
