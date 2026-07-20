# 배포 가이드 (Releasing)

hwhisper는 두 가지 배포 트랙이 있습니다.

- **무료 트랙 (현재 · 기본)** — 공증 없이 self-signed `.dmg` + 소스 공개. 사용자가 첫 실행 시 `xattr`로 격리 해제(README 설치 가이드 참고). 비용 0원, 지금 바로 가능.
- **공증 트랙 (D1)** — Apple Developer ID로 서명 + 공증(notarize)해서 **Gatekeeper 경고 없이 바로 열리는** 배포. 유료 Apple Developer Program이 필요. 아래는 이 트랙의 구체 플로우입니다.

---

## 무료 트랙 릴리스 절차 (현재)

```bash
bash scripts/make-app.sh      # dist/Hwhisper.app (hwhisper-dev self-signed 또는 ad-hoc)
bash scripts/make-dmg.sh      # dist/hwhisper-<버전>.dmg (hdiutil, 첫 실행 안내 동봉)
```

그 뒤:
1. GitHub에 저장소를 만들고 push (히스토리에 `.omc/` 없는 상태 — 이미 스쿼시됨).
2. GitHub Releases에서 새 릴리스(`v0.2.0`) 생성, `dist/hwhisper-0.2.0.dmg`를 아티팩트로 첨부.
3. 릴리스 노트에 README의 설치 가이드 링크 + 첫 실행 `xattr` 안내를 포함.

사용자 경험: 다운로드 → `.dmg` 열기 → 앱을 Applications로 드래그 → `xattr` 1회 → 실행.

---

## 공증 트랙 (D1) — 전체 플로우

### 선행 준비 (1회)

1. **Apple Developer Program 가입** — $99/년. https://developer.apple.com/programs/
2. **전체 Xcode 설치** — `notarytool`/`stapler`가 Xcode에 포함(현재 CLT-only 호스트엔 없음). App Store에서 Xcode 설치 후 `sudo xcode-select -s /Applications/Xcode.app`.
3. **Developer ID Application 인증서 발급** — Xcode > Settings > Accounts > Manage Certificates > `+` > "Developer ID Application", 또는 개발자 포털에서 생성해 로그인 키체인에 임포트. (무료 Apple ID로는 발급 불가 — 유료 프로그램 전용.)
4. **notarytool 자격 증명 저장** (앱 전용 암호 또는 App Store Connect API 키):
   ```bash
   # 앱 전용 암호는 appleid.apple.com > 로그인 및 보안 > 앱 암호에서 생성
   xcrun notarytool store-credentials "hwhisper-notary" \
     --apple-id "you@example.com" --team-id "TEAMID1234" --password "xxxx-xxxx-xxxx-xxxx"
   ```

### 릴리스마다 반복하는 8단계

```
[1] 빌드            swift build -c release
        │
[2] 서명            codesign --force --options runtime --timestamp \
        │             --sign "Developer ID Application: NAME (TEAMID)" \
        │             --entitlements hwhisper.entitlements dist/Hwhisper.app
        │           # --options runtime = Hardened Runtime (공증 필수 조건)
        │           # --timestamp = 보안 타임스탬프 (필수)
        ▼
[3] 서명 검증        codesign --verify --deep --strict --verbose=2 dist/Hwhisper.app
        ▼
[4] dmg 패키징       bash scripts/make-dmg.sh   (또는 create-dmg)
        ▼
[5] 공증 제출        xcrun notarytool submit dist/hwhisper-<버전>.dmg \
        │             --keychain-profile "hwhisper-notary" --wait
        │           # --wait: Apple 서버가 검사(보통 1~5분) 끝날 때까지 대기
        │           # Apple이 악성코드/서명/Hardened Runtime 자동 스캔
        ▼
[6] 스테이플         xcrun stapler staple dist/hwhisper-<버전>.dmg
        │           # 공증 티켓을 dmg에 "박아넣어" 오프라인에서도 검증되게 함
        ▼
[7] 최종 검증        spctl --assess --type open --context context:primary-signature \
        │             -v dist/hwhisper-<버전>.dmg      # → "accepted, source=Notarized Developer ID"
        │           xcrun stapler validate dist/hwhisper-<버전>.dmg
        ▼
[8] 배포            GitHub Releases에 dmg 업로드 (+ Sparkle appcast 갱신, 아래)
```

이렇게 배포된 dmg는 사용자가 **다운로드 → 열기 → 드래그 → 바로 실행**만 하면 됩니다. `xattr` 단계가 사라집니다.

> 이 8단계를 `scripts/make-app.sh`에 옵션(예: `--notarize`)으로 통합할 수 있습니다. 현재는 CLT-only 호스트라 `notarytool`이 없어 미구현 — Xcode 설치 후 추가 예정.

### 엔타이틀먼트 (`hwhisper.entitlements`, D1 시 생성)

Hardened Runtime에서 앱이 요구하는 권한을 명시해야 정상 동작합니다.

```xml
<key>com.apple.security.device.audio-input</key>   <true/>  <!-- 마이크 -->
<key>com.apple.security.automation.apple-events</key> <true/> <!-- 필요 시 -->
```
※ 접근성(AX)·전역 단축키는 엔타이틀먼트가 아니라 사용자가 시스템 설정에서 부여하는 TCC 권한이라 별도 선언 불필요.

---

## Sparkle 자동 업데이트 (D1 후속)

공증된 배포에는 자동 업데이트를 붙이는 게 자연스럽습니다. [Sparkle](https://sparkle-project.org/) 표준 플로우:

### 준비 (1회)
1. Sparkle을 SwiftPM 의존성으로 추가.
2. EdDSA 키 쌍 생성: `./bin/generate_keys` — 개인키는 키체인에, 공개키(`SUPublicEDKey`)는 `Info.plist`에.
3. `Info.plist`에 `SUFeedURL`(appcast.xml 위치, 예: GitHub Pages/Releases raw URL) 추가.

### 릴리스마다
```
[A] 위 공증 8단계로 dmg 생성
[B] dmg 서명:  ./bin/sign_update dist/hwhisper-<버전>.dmg   → EdDSA 서명 문자열 출력
[C] appcast.xml에 <item> 추가: 버전·다운로드 URL·서명·릴리스노트
[D] appcast.xml + dmg를 호스팅(GitHub Releases/Pages)에 업로드
```

### 사용자 쪽 (자동)
```
앱이 주기적으로 SUFeedURL(appcast.xml) 확인
   → 새 버전 발견 → "업데이트 있음" 다이얼로그
   → 사용자 승인 → dmg 다운로드
   → EdDSA 서명 + 공증 티켓 검증  ← 위변조 방지
   → 앱 교체 후 재실행
```

두 겹의 신뢰: **공증**(Apple이 악성코드 없음을 보증) + **EdDSA 서명**(업데이트가 우리 것임을 보증).

---

## 요약: 지금 vs D1

| | 무료 트랙 (지금) | 공증 트랙 (D1) |
|---|---|---|
| 비용 | 0원 | $99/년 + 전체 Xcode |
| 첫 실행 | `xattr` 1회 또는 시스템 설정 | 바로 실행 |
| 자동 업데이트 | 수동 재다운로드 | Sparkle 자동 |
| 사용자 마찰 | 낮음(1회성) | 없음 |
| 지금 가능? | ✅ | 계정·Xcode 준비 필요 |

비상업·개인 프로젝트에는 무료 트랙으로 충분합니다. 비개발자 대상으로 널리 퍼뜨릴 때 D1으로 전환하세요.
