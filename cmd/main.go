package main

import (
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/grahamgilbert/crypt/pkg/authmechs"
	"github.com/grahamgilbert/crypt/pkg/checkin"
	"github.com/grahamgilbert/crypt/pkg/logging"
	"github.com/grahamgilbert/crypt/pkg/pref"
	"github.com/grahamgilbert/crypt/pkg/utils"
)

var version = "development" // nolint:gochecknoglobals

func main() {

	if os.Geteuid() != 0 {
		fmt.Println("Crypt must be run as root!")
		os.Exit(1)
	}

	install := flag.Bool("install", false, "Install the AuthDB mechanisms")
	uninstall := flag.Bool("uninstall", false, "Uninstall the AuthDB mechanisms")
	checkMechs := flag.Bool("check-auth-mechs", false, "Check the AuthDB mechanisms. Returns 0 if all are present, 1 if not.")
	versionFlag := flag.Bool("version", false, "print the version")
	flag.Parse()

	if *versionFlag {
		fmt.Println(version)
		os.Exit(0)
	}

	// Every standard log record keeps going to stderr for launchd and is also
	// written to the file log. Errors that end the run are recorded at ERROR.
	log.SetOutput(logging.TeeWriter(os.Stderr, logging.LevelInfo))
	stderr := log.New(os.Stderr, "", log.LstdFlags)
	fail := func(phase string, err error) {
		logging.Error("%s failed: %v", phase, err)
		stderr.Println(err)
		os.Exit(1)
	}

	p := pref.New()
	r := utils.NewRunner()
	if *install {
		logging.Info("Installing authorization mechanisms (version %s)", version)
		err := authmechs.Run(r, true)
		if err != nil {
			fail("Installing authorization mechanisms", err)
		}
		logging.Info("Installed authorization mechanisms")
	} else if *uninstall {
		logging.Info("Removing authorization mechanisms (version %s)", version)
		err := authmechs.Run(r, false)
		if err != nil {
			fail("Removing authorization mechanisms", err)
		}
		logging.Info("Removed authorization mechanisms")
	} else if *checkMechs {
		err := authmechs.Check(r)
		if err != nil {
			fail("Checking authorization mechanisms", err)
		}
	} else {
		logging.Info("Checkin started (version %s)", version)
		err := checkin.RunEscrow(r, p)
		if err != nil {
			fail("Checkin", err)
		}
		logging.Info("Checkin finished")
	}

	os.Exit(0)
}
