use utils.nu *

def quote [...t] {
    let s = $t | str join '' | str replace -a "'" "''"
    $"'($s)'"
}

def flatten_fields [args] {
    let f = $in | default [] | where {|x| $x | is-not-empty }
    let prefix = $args.0
    let inner = $args.1
    let outer = $args.2
    if ($f | is-not-empty) {
        $f
        | each {|x|
            if ($x | describe -d).type == list {
                $x | str join $inner
            } else {
                $x
            }
        }
        | str join $outer
        | do { (if ($prefix | is-empty) {[$in]} else {[$prefix $in]})}
    } else { [] }
}

def sql [q] {
    [
        [$q.select   ['select',   ' as ', ', ']]
        [$q.from     ['from',     ' as ', ' join ']]
        [$q.where?   ['where',    ' ',    ' and ']]
        [$q.whereOr? ['or',       ' ',    ' or ']]
        [$q.groupBy? ['group by', null,   ', ']]
        [$q.orderBy? ['order by', ' ',    ', ']]
        [$q.limit?   ['limit',    null,   ' offset ']]
    ]
    | each {|x| $x.0 | flatten_fields $x.1 }
    | flatten
    | str join ' '
}

export def 'history timing' [
    pattern?
    --exclude(-x): string
    --num(-n)=10
    --current(-c)
    --all(-a)
] {
    open $nu.history-path | query db (sql {
        from: [history]
        where: [
            "cmd not like 'history timing%'"
            (if ($pattern | is-not-empty) {[cmd like (quote '%' $pattern '%')]})
            (if ($exclude | is-not-empty) {[cmd not like (quote '%' $exclude '%')]})
            (if $current {[session_id = (history session)]})
            (if not $all {[cwd = (quote $env.PWD)]})
        ]
        orderBy: [[start desc]]
        select: [
            [start_timestamp start]
            [command_line cmd]
            [duration_ms duration]
            (if $all {[$"replace\(cwd, '($env.HOME)', '~')" cwd]})
            [exit_status exit]
        ]
        limit: [$num]
    })
    | update duration {|x| $x.duration | default 0 | do { $in * 1_000_000 } | into duration }
    | update start {|x| $x.start | into int | do { $in * 1_000_000 } | into datetime }
}

def cmpl-history-dir [] {
    open $nu.history-path | query db (sql {
        select: [cwd ['count(1)' count]]
        from: history
        groupBy: [cwd]
        orderBy: ['count desc']
        limit: 20
    })
    | rename value description
    | update value {|x| $x.value | str replace $env.HOME '~' }
}

export def 'history top' [
    num=10
    --before (-b): duration
    --dir (-d)
    --path(-p): list<string@cmpl-history-dir>
] {
    open $nu.history-path | query db (sql {
        from: [history]
        select: [
            (if $dir {[$"replace\(cwd, '($env.HOME)', '~')" cwd]} else {[command_line cmd]})
            ['count(1)' count]
        ]
        where: [
            (if ($before | is-not-empty) {
                let ts = (date now) - $before | into int | do { $in / 1_000_000 }
                [start_timestamp > $ts]
            })
            (if ($path | is-not-empty) {
                let ps = $path | path expand | each { quote $in } | str join ', '
                [cwd in '(' $ps  ')']
            })
        ]
        groupBy: [(if $dir {'cwd'} else {'cmd'})]
        orderBy: [[count desc]]
        limit: [$num]
    })
    | histogram-column count
}

def cmpl-interval [] {
    [hour day month year]
}

export def 'history activities' [
    --limit(-l):int=21
    --interval(-i): string@cmpl-interval
] {
    let dfs = match $interval {
        'hour' => '%Y-%m-%d %H'
        'day' => '%Y-%m-%d'
        'month' => '%Y-%m'
        'year' => '%Y'
        _ => '%Y-%m-%d'
    }
    open $nu.history-path | query db (sql {
        from: [history]
        select: [
            [$"strftime\('($dfs)', DATETIME\(ROUND\(start_timestamp / 1000\), 'unixepoch'\)\)" 'date']
            ['count(1)' count]
        ]
        limit: [$limit]
        groupBy: ['date']
        orderBy: [['date', desc]]
    })
    | reverse
    | histogram-column count
}

export def 'history clean' [
    keyword
    --cwd
] {
    let tg = if $cwd { 'cwd' } else { 'command_line' }
    let fr = $"from history where ($tg) like (quote '%' $keyword '%')"
    let l = open $nu.history-path | query db  $"select * ($fr)"
    if ($l | is-empty) {
        print 'nothing to clean'
    } else {
        print $l
        if ([y n] | input list 'continue? ') == 'y' {
            open $nu.history-path | query db  $"delete ($fr)"
        }
    }
}