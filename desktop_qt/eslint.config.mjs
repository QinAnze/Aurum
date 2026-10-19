// 只检查自维护脚本；上游、依赖和生成文件保留原样。
export default [
    {
        ignores: ['node_modules/**', 'output/**', 'vendor/**', 'MusicBridge/upstream/**'],
    },
    {
        files: [
            'Qt/tests/**/*.{mjs,cjs}',
            'MusicBridge/*.cjs',
            'MusicBridge/client/**/*.mjs',
            'scripts/*.{cjs,mjs}',
            'eslint.config.mjs',
        ],
        languageOptions: {
            ecmaVersion: 'latest',
            sourceType: 'module',
        },
        rules: {
            curly: ['error', 'all'],
            'one-var': ['error', 'never'],
            'no-nested-ternary': 'error',
            'no-sequences': ['error', { allowInParentheses: false }],
            'no-empty': 'error',
        },
    },
];
