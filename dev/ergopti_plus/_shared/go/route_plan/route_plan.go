package routeplan

import (
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// The per-origin route plan mirrors _shared/lua/network/route_plan.lua and the
// shell twin in macos/modules/llm/network-retry.sh. All three answer the same
// vectors (_shared/tests/corpus/network/route_plan_vectors.json). A client that
// only reads an environment relay holds one relay for the whole download, so
// the plan turns the route a native lookup named for each origin into that
// relay plus a bypass list, and re-evaluates every redirect target against it.

// Closed refusal reasons: never a URL, a relay address or a PAC fragment.
const (
	RoutePlanEmpty         = "route-plan-empty"
	RoutePlanInvalid       = "route-plan-invalid"
	RoutePlanConflict      = "route-plan-conflict"
	RoutePlanUnplannedHost = "route-plan-unplanned-host"
)

// RouteEntry is one lookup result: an https origin and its route, either
// "direct" or an http, https, socks5 or socks5h relay URL with a port and an
// optional userinfo (an apostrophe in it must be percent-encoded).
type RouteEntry struct {
	Origin string
	Route  string
}

// RoutePlan is the environment a lookup set can be exported as.
type RoutePlan struct {
	// Proxy is the single relay, or "direct" when no origin needs one.
	Proxy  string
	hosts  map[string]string
	direct []string
}

var (
	routeOriginPattern = regexp.MustCompile(`^https://([^/?#@:\s]+)$`)
	routeRelayPattern  = regexp.MustCompile(`^(?:https?|socks5h?)://(?:[A-Za-z0-9._~%!$&()*+,;=:-]+@)?(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+):([0-9]+)$`)
	routeHostPattern   = regexp.MustCompile(`^[A-Za-z0-9.-]+$`)
)

// routeHost lowercases a DNS host and drops one trailing dot.
func routeHost(host string) (string, bool) {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if host == "" || len(host) > 253 || !routeHostPattern.MatchString(host) || strings.Contains(host, "..") {
		return "", false
	}
	return host, true
}

func validRoute(route string) bool {
	if route == "direct" {
		return true
	}
	match := routeRelayPattern.FindStringSubmatch(route)
	if match == nil || len(match[2]) > 5 {
		return false
	}
	port, err := strconv.Atoi(match[2])
	return err == nil && port >= 1 && port <= 65535
}

// NewRoutePlan builds the plan of one client's ordered lookups. Every entry is
// validated before any conflict is judged, so an invalid entry always wins.
func NewRoutePlan(entries []RouteEntry) (*RoutePlan, string) {
	if len(entries) == 0 {
		return nil, RoutePlanEmpty
	}
	type item struct{ host, route string }
	items := make([]item, 0, len(entries))
	for _, entry := range entries {
		match := routeOriginPattern.FindStringSubmatch(entry.Origin)
		if match == nil || !validRoute(entry.Route) {
			return nil, RoutePlanInvalid
		}
		host, ok := routeHost(match[1])
		if !ok {
			return nil, RoutePlanInvalid
		}
		items = append(items, item{host, entry.Route})
	}
	plan := &RoutePlan{Proxy: "direct", hosts: make(map[string]string)}
	relay := ""
	for _, current := range items {
		if known, seen := plan.hosts[current.host]; seen {
			if known != current.route {
				return nil, RoutePlanConflict
			}
			continue
		}
		plan.hosts[current.host] = current.route
		if current.route == "direct" {
			plan.direct = append(plan.direct, current.host)
		} else if relay != "" && relay != current.route {
			return nil, RoutePlanConflict
		} else {
			relay = current.route
		}
	}
	if relay != "" {
		plan.Proxy = relay
	}
	return plan, ""
}

// NoProxy lists the origins the lookup sent direct while a relay is set, in
// first-appearance order.
func (p *RoutePlan) NoProxy() string {
	if p.Proxy == "direct" {
		return ""
	}
	return strings.Join(p.direct, ",")
}

// Redirect re-evaluates one redirect target. It returns "proxy" or "direct",
// or a closed refusal: a downgrade or malformed target is invalid, a host the
// plan never looked up is refused because its route is unknown.
func (p *RoutePlan) Redirect(target string) (string, string) {
	if strings.ContainsAny(target, "\\ \t\r\n") || strings.IndexFunc(target, func(r rune) bool { return r < 32 || r == 127 }) >= 0 {
		return "", RoutePlanInvalid
	}
	parsed, err := url.Parse(target)
	if err != nil || parsed.Scheme != "https" {
		return "", RoutePlanInvalid
	}
	host, ok := routeHost(parsed.Hostname())
	if !ok {
		return "", RoutePlanInvalid
	}
	route, planned := p.hosts[host]
	if !planned {
		return "", RoutePlanUnplannedHost
	}
	if route == "direct" {
		return "direct", ""
	}
	return "proxy", ""
}
