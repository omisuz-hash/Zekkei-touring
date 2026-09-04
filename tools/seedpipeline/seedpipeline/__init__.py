"""絶景道シード自動収集パイプライン。

YouTube Data API で動画を探し、Gemini API で道を抽出し、地図 API で道路の形状を付け、
重複を統合して Supabase 用のシード SQL を出力する。人手を介さずに初期データを蓄積する。
"""
