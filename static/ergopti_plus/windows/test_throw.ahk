try throw Error()
catch as e {
    FileAppend(e.Stack, "*")
}
