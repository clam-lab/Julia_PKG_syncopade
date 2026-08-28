# Syncopade ノード実行排他性 改定依頼書

## 文書情報

- 依頼元リポジトリ: `Julia_script_ManipMDO_ICRA2027`
- 依頼先リポジトリ: `Julia_PKG_syncopade`
- 調査対象Syncopade revision: `8ec26972020072a77926137462df0d65f81f8547`
- 発行日: 2026-08-28
- 文書種別: 依頼元リポジトリの実装Todoではなく、上流リポジトリへの改定依頼

## 依頼概要

Syncopadeが現在採用している `idle` / `busy` のノード管理モデルにおいて、
意図せず同一ノード上で複数の計算ジョブが重複実行されないよう、ノード予約、
dispatch、計算serverの実行状態管理を再検討し、必要な改定を行ってほしい。

本依頼書では詳細な実装方法を指定しない。排他制御、予約、受付拒否、待ち行列化
などの具体的な設計は、Syncopadeの公開interfaceと今後の運用方針を踏まえて、
Syncopade側で決定することを想定している。

## 1. どんな問題があるか

### 観測された障害

TOuNN4MTのmultistart計算20件を、1台のSyncopade conductorから利用可能な
8台の計算nodeへ独立したtaskとして投入した。20件すべてのcallbackは返ったが、
計算が完了したのは19件であり、残る1件は計算用child processの起動前に次の
errorで停止した。

```text
ArgumentError: worker environment is missing package UUID
f50b26cd-6da7-4582-8e3a-7596c54f4e79
```

このUUIDは `Julia_PKG_TOuNN4MT` を示す。配置済みの `Project.toml` と
`Manifest.toml` には、該当packageと固定revisionが正しく含まれている。
また、同一環境を直列に検査した場合は、このpackageを正常に解決できる。

最終batchで得られた事実は次のとおりである。

- batch ID: `syncopade-20260828T091117.648Z-pid84036`
- 計画数 / 投入数 / callback数: 20 / 20 / 20
- 検証済み計算結果: 19件
- worker環境error: 1件
- 失敗したlogical job: `tounn-run-0002`
- 失敗phase: `Pkg.instantiate()` 後のworker環境検証
- child process: 未起動

5回の20-run試行を通して、同じpackage UUID欠落errorを合計6件確認した。
先行試行で併発したGit認証errorは別途解消されている。20件すべてについて
Git認証errorなしでcallbackが返った最終試行でも、このUUID欠落errorだけが
1件残った。

### 再現できた発生機構

worker taskは、NFS上へ固定配置したJulia環境を一時的にactivateし、
`Pkg.dependencies()` で依存packageを検証している。直列実行では311件の依存が
取得され、`Julia_PKG_TOuNN4MT` も含まれる。

同一Julia process内の2つの非同期jobで `Pkg.activate(...) do` が重なると、
一方のjobが処理中であるにもかかわらず、他方のjobがprocess全体で共有される
active projectを元の環境へ戻すことができる。このとき、処理中のjobは別環境を
対象として `Pkg.dependencies()` を実行する。局所再現では依存が251件となり、
TOuNN4MTのUUIDが欠落した。これはremoteで発生したerror条件と一致する。

調査対象revisionのSyncopadeには、次の動作が確認された。

1. conductorは `SUBMIT` ごとに非同期の即時dispatch処理を開始する。
2. 各処理はdispatch lockへ入る前にnode状態を取得する。
3. 取得した状態を共有node状態へ反映するまでの間に、別のdispatchによって
   その状態が古くなる可能性がある。
4. 計算serverはjob開始応答を返した後に、自身を `busy` へ変更する。
5. 計算serverは、すでに `busy` の場合も計算要求を明示的に拒否せず、受理した
   各jobを非同期に実行する。
6. 複数jobが実行中であっても、いずれか1件の終了処理がserver状態を `idle` へ
   戻す。

このため、conductorと計算serverを合わせても、nodeが排他的に予約されることが
保証されていない。同一server process内で独立jobが重なると、Juliaのactive
package環境のようなprocess共有状態がjob間で競合する。

## 2. 何に影響しているか

### 確認済みの影響

- 固定済みpackage環境が正しい場合でも、計算開始前に有効なtaskが失敗する。
- 20件すべてのcallbackを受信しても、計画した計算結果の一部が欠落し得る。
- 発生箇所はtimingに依存し、同じ入力でも失敗するlogical run IDが固定されない。
  したがって、同じ入力の再投入は再現可能な解決にならない。
- 本問題が残る間、依頼元リポジトリではSyncopade transportの受入検証を完了
  できない。

### Syncopade全体に関係する運用上のrisk

- 1つの `idle` / `busy` 実行資源として扱っているnode上で、高負荷計算が同時
  実行される可能性がある。
- 重複jobの一方が終了すると、他方が実行中でもnodeが `idle` と報告され、さらに
  jobが投入される可能性がある。
- process共有状態を変更するremote関数は、同一server process内の別jobへ干渉
  し得る。今回確認したpackage activation以外にも、working directory、環境変数、
  module loading、cache、global configurationなどが同種の影響を受ける可能性が
  ある。
- 実行時間、memory使用量、数値計算のthroughputが、上位MDOのschedulerと監査
  記録が想定する条件から外れる可能性がある。
- 現在の依頼元側result evidenceだけでは、conductor task IDと実行nodeの対応を
  検証できず、timing依存障害の事後特定が難しい。

これはSyncopadeの汎用task実行に関する問題であり、TOuNNのalgorithm、数値model、
またはpackage依存graphに固有の問題ではない。

## 3. どのような改定が必要か

Syncopade側で設計を再検討し、少なくとも次の振る舞いを満たす改定を依頼する。

### Node予約とdispatch

- 現在の単一資源 `idle` / `busy` modelを維持する場合、1台のnodeでactiveとなる
  計算jobは最大1件とする。
- 観測した `idle` 状態から予約済みまたは `busy` 状態への遷移は、競合する
  dispatch処理に対してatomicでなければならない。
- 古い状態取得結果が、後から成立した予約または `busy` 状態を上書きしては
  ならない。
- 多数の `SUBMIT` が短時間に到着しても、lock外で取得した独立の状態snapshotを
  根拠として、同一nodeを重複選択してはならない。

### 計算serverの振る舞い

- 1件のみを実行するmodelを採用する場合、serverは `busy` 中の2件目を暗黙に
  受理してはならない。
- 受付拒否、保留、server側queueのいずれを選ぶかはSyncopade側で決定してよいが、
  conductorからその結果を判別できなければならない。
- 採用したmodelで受理済みの全jobが終端状態になるまで、nodeは `idle` を報告
  してはならない。
- status応答、開始応答、完了通知、内部実行状態が、同じjob lifecycleを表さなければ
  ならない。

### Evidenceと診断性

- conductor task ID、worker node、worker job IDを1つのdispatch recordとして
  追跡可能にすることが望ましい。
- 予約成功、受付拒否、保留を監査logで区別できることが望ましい。
- 現在のchecksum、callback、`DONE` evidenceは継続利用できるようにする。

### Syncopade側で確認してほしい検証scenario

少なくとも、次の条件をtestまたは同等の再現可能な検証で確認してほしい。

1. 利用可能node数を超えるtaskを短時間に一括投入する。
2. 複数の `SUBMIT` 即時処理が、遅延した状態応答または古い状態応答を受け取る。
3. すでに `busy` の計算serverへ、さらに計算要求が到着する。
4. 複数jobを許可する設計を選ぶ場合、一方のjobだけが先に終了する。
5. node予約中にnode障害またはdispatch障害が発生する。
6. 既存の公開conductor/client投入interfaceとcallback flowとの互換性を確認する。

受入結果では、厳密な1 node 1 job実行を保証するか、または状態分離とactive job数の
正しい管理を備えた複数job modelを明文化して保証する必要がある。依頼元MDO taskの
`Pkg.activate` だけを直列化する対応は、確認済み症状の1つを隠すだけで、Syncopadeの
node予約と資源管理の不整合を残すため、本問題の解決とは扱わない。

## 責務境界

依頼元リポジトリは、task入力、immutableなNFS配置、domain result検証、実験receiptを
引き続き所有する。SyncopadeにTOuNN4MT、Julia package Manifest、またはMDO semanticsの
理解は要求しない。

具体的な関数仕様、対象file、移行方法、release計画は本依頼書では規定しない。
`Julia_PKG_syncopade` リポジトリにおけるTodoおよびphase運用の中で検討することを
想定する。
