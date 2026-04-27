# dan-hebrew

שני כלים ל-macOS שמקלים על העבודה בעברית, מבוססים על Hammerspoon:

- **המרת שפה (EN ⇄ HE)** — סימון טקסט שהוקלד בפריסה הלא נכונה והמרתו בקיצור מקלדת.
- **מנהל Clipboard** — היסטוריית clipboard עם תמיכה בתמונות, pinned items, וקיצורי מקלדת לפריטים נפוצים.

## דרישות

- macOS 12 ומעלה.
- [Hammerspoon](https://www.hammerspoon.org/) — חינמי, קוד פתוח.

## התקנה

### 1. התקנת Hammerspoon

```bash
brew install --cask hammerspoon
```

או הורדה ישירה מ-[hammerspoon.org](https://www.hammerspoon.org/).

### 2. הרשאות Accessibility

לפתוח את `System Settings` → `Privacy & Security` → `Accessibility` → להוסיף את Hammerspoon ולהפעיל את ה-toggle. בלי זה, קיצורי המקלדת לא יעבדו.

### 3. שכפול הריפו

```bash
git clone https://github.com/yedidya-buildfy/dan-hebrew.git ~/dan-hebrew
cd ~/dan-hebrew
./install.sh
```

הסקריפט יוצר symlinks מ-`~/.hammerspoon/` אל קבצי המקור. אם כבר יש לך `init.lua` ב-`~/.hammerspoon/`, הוא ישמור גיבוי ולא ידרוס — תצטרך למזג ידנית את התוכן של `src/init.lua` לתוך ה-`init.lua` הקיים שלך.

### 4. טעינה

לפתוח את Hammerspoon. אם הוא רץ — לחיצה על האייקון בשורת התפריטים → `Reload Config`. צריכה להופיע הודעת `✓ dan-hebrew loaded`.

## שימוש

### המרת שפה — ברירת מחדל: `Cmd+Alt+K`

- **עם סימון** — מסמנים טקסט בכל אפליקציה, לוחצים על הקיצור. הטקסט מומר לפריסה השנייה (אנגלית ↔ עברית), פריסת המקלדת עוברת לשפת היעד, ו-Caps Lock מכובה.
- **בלי סימון** — לחיצה על הקיצור מחליפה את פריסת המקלדת בלבד (toggle).

#### מפת המקשים

מבוססת על פריסת `com.apple.keylayout.Hebrew` הסטנדרטית של macOS. כוללת תמיכה בכל האותיות, סימני פיסוק (`,`, `.`, `/`, `;`, `'`, `[`, `]`, `` ` ``), ושני וריאנטים של גרש (`'` ו-`׳`).

#### מגבלת טרמינלים

באפליקציות טרמינל (Terminal.app, iTerm2, וכן בפאנל הטרמינל המוטמע ב-IDE-ים: VS Code, Cursor, Windsurf, Antigravity), ההמרה מבוצעת רק על טקסט בסוף השורה. הסיבה: ב-xterm.js הסמן של ה-shell מנותק מהסימון הוויזואלי של העכבר, ואין דרך אמינה למקם את הסמן על מילה באמצע השורה ללא תמיכה מהאפליקציה עצמה.

המעקף: לסמן מהמילה ועד סוף השורה, להמיר, ואז לתקן את החלק המיותר.

### מנהל Clipboard — ברירת מחדל: `Cmd+Alt+V`

לחיצה על הקיצור פותחת פאנל עם שני טורים:

- **Recent (שמאל)** — היסטוריה של פעולות העתקה (טקסט ותמונות), עד 100 פריטים.
- **Pinned (ימין)** — פריטים שננעצו ידנית, עם קיצורי מקלדת לכל אחד.

#### ניווט ופעולות

- חיצים — מעבר בין פריטים.
- Enter — הדבקת הפריט הנבחר באפליקציה הקודמת.
- Esc — סגירת הפאנל.
- אייקון נעץ ליד פריט ב-Recent — נעיצה לטור ה-Pinned.
- מחיקת פריט — דרך כפתור ה-X.

הפריטים נשמרים בקבצי JSON ב-`~/.hammerspoon/`:
- `clipboard-recent.json` — היסטוריה.
- `clipboard-pinned.json` — pinned items.
- `clipboard-images/` — תמונות.

### ניהול קיצורי מקלדת — `Cmd+Alt+H`

פתיחת UI לעריכת ה-mods וה-key של שני הקיצורים. אחרי שמירה, Hammerspoon נטען מחדש אוטומטית.

## קבצים שמיוצרים אוטומטית (לא ב-git)

הקבצים האלה נוצרים בזמן ריצה ב-`~/.hammerspoon/` ומופיעים ב-`.gitignore`:

- `hotkeys.json` — הגדרות הקיצורים של המשתמש.
- `hotkey_usage.json` — מוני שימוש.
- `clipboard-recent.json`, `clipboard-pinned.json`, `clipboard-images/` — נתוני ה-clipboard manager.

## מבנה הריפו

```
dan-hebrew/
├── README.md
├── LICENSE                 ← MIT
├── .gitignore
├── install.sh              ← symlinks ל-~/.hammerspoon
└── src/
    ├── init.lua            ← bind של הקיצורים
    ├── language_converter.lua
    ├── clipboard_manager.lua
    └── hotkey_manager.lua  ← UI + persistence של הקיצורים
```

## הסרת ההתקנה

```bash
rm ~/.hammerspoon/{init,language_converter,clipboard_manager,hotkey_manager}.lua
rm -rf ~/dan-hebrew
```

אם היה לך גיבוי `init.lua.bak.*` — אפשר לשחזר אותו חזרה ל-`init.lua`.

## רישיון

MIT — ראה [LICENSE](LICENSE).
