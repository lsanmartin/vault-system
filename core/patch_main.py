import sys

def patch_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    search_colorscheme = """        case .dark, .night, .glass: return .dark"""
    replace_colorscheme = """        case .dark, .night: return .dark"""
    content = content.replace(search_colorscheme, replace_colorscheme)

    search_sidebar = """.background(viewModel.selectedTheme == .glass ? AnyView(Rectangle().fill(.ultraThinMaterial)) : AnyView(viewModel.macSidebar))"""
    replace_sidebar = """.background(viewModel.selectedTheme == .night ? AnyView(viewModel.macSidebar) : AnyView(Rectangle().fill(.ultraThinMaterial)))"""
    content = content.replace(search_sidebar, replace_sidebar)

    search_main = """.background(viewModel.selectedTheme == .glass ? AnyView(Rectangle().fill(.ultraThinMaterial)) : AnyView(viewModel.macBackground))"""
    replace_main = """.background(viewModel.selectedTheme == .night ? AnyView(viewModel.macBackground) : AnyView(Rectangle().fill(.ultraThinMaterial)))"""
    content = content.replace(search_main, replace_main)

    search_html = """        case .light: themeCSS = ":root { --bg: #fff; --text: #333; --accent: #2b82d9; }"
        case .dark: themeCSS = ":root { --bg: #282828; --text: rgba(240, 240, 240, 0.85); --accent: #58a6ff; }"
        case .glass: themeCSS = ":root { --bg: transparent; --text: rgba(255, 255, 255, 0.9); --accent: #00e5ff; } body { background: transparent; }"
        case .night: themeCSS = ":root { --bg: #000; --text: #ff3b30; --accent: #ff453a; } body { background:#000; color:#ff3b30; }"
        case .system: themeCSS = "@media (prefers-color-scheme: dark) { :root { --bg: transparent; --text: rgba(240, 240, 240, 0.85); --accent: #58a6ff; } } @media (prefers-color-scheme: light) { :root { --bg: transparent; --text: #333; --accent: #2b82d9; } } body { background: transparent; }\""""
        
    replace_html = """        case .light: themeCSS = ":root { --bg: transparent; --text: #333; --accent: #2b82d9; } body { background: transparent; }"
        case .dark: themeCSS = ":root { --bg: transparent; --text: rgba(240, 240, 240, 0.85); --accent: #58a6ff; } body { background: transparent; }"
        case .night: themeCSS = ":root { --bg: #000; --text: #ff3b30; --accent: #ff453a; } body { background:#000; color:#ff3b30; }"
        case .system: themeCSS = "@media (prefers-color-scheme: dark) { :root { --bg: transparent; --text: rgba(240, 240, 240, 0.85); --accent: #58a6ff; } } @media (prefers-color-scheme: light) { :root { --bg: transparent; --text: #333; --accent: #2b82d9; } } body { background: transparent; }\""""

    # But wait, earlier I replaced .dark, so the search string might be different! 
    # Let's do a more robust replacement.
    pass
