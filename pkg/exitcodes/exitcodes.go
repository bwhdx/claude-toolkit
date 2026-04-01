// Package exitcodes defines standardized exit codes for all claude-toolkit CLIs.
//
// All tools in the toolkit use these codes so consumers can programmatically
// determine what happened without parsing stderr.
package exitcodes

const (
	// OK indicates successful execution.
	OK = 0

	// GeneralError indicates an unspecified error.
	GeneralError = 1

	// UsageError indicates invalid arguments or flags.
	UsageError = 2

	// NotFound indicates a requested resource was not found.
	NotFound = 3

	// AuthError indicates an authentication failure.
	AuthError = 10

	// AuthExpired indicates expired credentials that need refresh.
	AuthExpired = 11

	// RateLimited indicates a rate limit was hit.
	RateLimited = 75

	// SubscriptionLimited indicates a subscription usage limit was hit.
	SubscriptionLimited = 76

	// AllAccountsLimited indicates all accounts are limited (cc-auth cycle failed).
	AllAccountsLimited = 77

	// LockConflict indicates another process holds a required lock.
	LockConflict = 80

	// NotInitialized indicates required setup has not been done.
	NotInitialized = 90
)
