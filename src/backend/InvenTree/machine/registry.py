"""Machine registry."""

from typing import Union, cast
from uuid import UUID

from django.core.cache import cache
from django.db.utils import IntegrityError, OperationalError, ProgrammingError

import structlog

from common.settings import get_global_setting, set_global_setting
from InvenTree.helpers_mixin import get_shared_class_instance_state_mixin
from machine.machine_type import BaseDriver, BaseMachineType

logger = structlog.get_logger('inventree')


class MachineRegistry(
    get_shared_class_instance_state_mixin(lambda _x: 'machine:registry')
):
    """Machine registry class."""

    def __init__(self) -> None:
        """Initialize machine registry.

        Set up all needed references for internal and external states.
        """
        self.machine_types: dict[str, type[BaseMachineType]] = {}
        self.drivers: dict[str, type[BaseDriver]] = {}
        self.driver_instances: dict[str, BaseDriver] = {}
        self.machines: dict[str, BaseMachineType] = {}

        self.base_drivers: list[type[BaseDriver]] = []

        # Keep an internal hash of the machine registry state
        self._hash = None

    @property
    def errors(self) -> list[Union[str, Exception]]:
        """List of registry errors."""
        return cast(list[Union[str, Exception]], self.get_shared_state('errors', []))

    def handle_error(self, error: Union[Exception, str]):
        """Helper function for capturing errors with the machine registry."""
        self.set_shared_state('errors', [*self.errors, error])

    def initialize(self, main: bool = False):
        """Initialize the machine registry."""
        # clear cache for machines (only needed for global redis cache)
        if main and hasattr(cache, 'delete_pattern'):  # pragma: no cover
            cache.delete_pattern('machine:*')

        self.discover_machine_types()
        self.discover_drivers()
        self.load_machines(main=main)

    def discover_machine_types(self):
        """Discovers all machine types by inferring all classes that inherit the BaseMachineType class."""
        import InvenTree.helpers

        logger.debug('Collecting machine types')

        machine_types: dict[str, type[BaseMachineType]] = {}
        base_drivers: list[type[BaseDriver]] = []

        discovered_machine_types: set[type[BaseMachineType]] = (
            InvenTree.helpers.inheritors(BaseMachineType)
        )
        for machine_type in discovered_machine_types:
            try:
                machine_type.validate()
            except NotImplementedError as error:
                self.handle_error(error)
                continue

            if machine_type.SLUG in machine_types:
                self.handle_error(
                    ValueError(f"Cannot re-register machine type '{machine_type.SLUG}'")
                )
                continue

            machine_types[machine_type.SLUG] = machine_type
            base_drivers.append(machine_type.base_driver)

        self.machine_types = machine_types
        self.base_drivers = base_drivers

        logger.debug('Found %s machine types', len(self.machine_types.keys()))

    def discover_drivers(self):
        """Discovers all machine drivers by inferring all classes that inherit the BaseDriver class."""
        import InvenTree.helpers

        logger.debug('Collecting machine drivers')

        drivers: dict[str, type[BaseDriver]] = {}

        discovered_drivers: set[type[BaseDriver]] = InvenTree.helpers.inheritors(
            BaseDriver
        )
        for driver in discovered_drivers:
            # skip discovered drivers that define a base driver for a machine type
            if driver in self.base_drivers:
                continue

            try:
                driver.validate()
            except NotImplementedError as error:
                self.handle_error(error)
                continue

            if driver.SLUG in drivers:
                self.handle_error(
                    ValueError(f"Cannot re-register driver '{driver.SLUG}'")
                )
                continue

            drivers[driver.SLUG] = driver

        self.drivers = drivers

        logger.debug('Found %s machine drivers', len(self.drivers.keys()))

    def get_driver_instance(self, slug: str):
        """Return or create a driver instance if needed."""
        if slug not in self.driver_instances:
            driver = self.drivers.get(slug, None)
            if driver is None:
                return None

            self.driver_instances[slug] = driver()

        return self.driver_instances.get(slug, None)

    def load_machines(self, main: bool = False):
        """Load all machines defined in the database into the machine registry."""
        # Imports need to be in this level to prevent early db model imports
        from machine.models import MachineConfig

        for machine_config in MachineConfig.objects.all():
            self.add_machine(
                machine_config, initialize=False, update_registry_hash=False
            )

        # initialize machines only in main thread
        if main:
            # initialize drivers
            for driver in self.driver_instances.values():
                driver.init_driver()

            # initialize machines after all machine instances were created
            for machine in self.machines.values():
                if machine.active:
                    machine.initialize()

            logger.info('Initialized %s machines', len(self.machines.keys()))
        else:
            logger.info('Loaded %s machines', len(self.machines.keys()))

        self._update_registry_hash()

    def reload_machines(self):
        """Reload all machines from the database."""
        self.machines = {}
        self.load_machines()

    def add_machine(self, machine_config, initialize=True, update_registry_hash=True):
        """Add a machine to the machine registry."""
        machine_type = self.machine_types.get(machine_config.machine_type, None)
        if machine_type is None:
            self.handle_error(f"Machine type '{machine_config.machine_type}' not found")
            return

        machine: BaseMachineType = machine_type(machine_config)
        self.machines[str(machine.pk)] = machine

        if initialize and machine.active:
            machine.initialize()

        if update_registry_hash:
            self._update_registry_hash()

    def update_machine(
        self, old_machine_state, machine_config, update_registry_hash=True
    ):
        """Notify the machine about an update."""
        if machine := machine_config.machine:
            machine.update(old_machine_state)

            if update_registry_hash:
                self._update_registry_hash()

    def restart_machine(self, machine):
        """Restart a machine."""
        machine.restart()

    def remove_machine(self, machine: BaseMachineType):
        """Remove a machine from the registry."""
        self.machines.pop(str(machine.pk), None)
        self._update_registry_hash()

    def get_machines(self, **kwargs):
        """Get loaded machines from registry (By default only initialized machines).

        Kwargs:
            name: Machine name
            machine_type: Machine type definition (class)
            driver: Machine driver (class)
            initialized (bool | None): use None to get all machines (default: True)
            active: (bool)
            base_driver: base driver (class)
        """
        self._check_reload()

        allowed_fields = [
            'name',
            'machine_type',
            'driver',
            'initialized',
            'active',
            'base_driver',
        ]

        if 'initialized' not in kwargs:
            kwargs['initialized'] = True
        if kwargs['initialized'] is None:
            del kwargs['initialized']

        def filter_machine(machine: BaseMachineType):
            for key, value in kwargs.items():
                if key not in allowed_fields:
                    raise ValueError(
                        f"'{key}' is not a valid filter field for registry.get_machines."
                    )

                # check if current driver is subclass from base_driver
                if key == 'base_driver':
                    if machine.driver and not issubclass(
                        machine.driver.__class__, value
                    ):
                        return False

                # check if current machine is subclass from machine_type
                elif key == 'machine_type':
                    if issubclass(machine.__class__, value):
                        return False

                # check attributes of machine
                elif value != getattr(machine, key, None):
                    return False

            return True

        return list(filter(filter_machine, self.machines.values()))

    def get_machine(self, pk: Union[str, UUID]):
        """Get machine from registry by pk."""
        self._check_reload()
        return self.machines.get(str(pk), None)

    def get_drivers(self, machine_type: str):
        """Get all drivers for a specific machine type."""
        return [
            driver
            for driver in self.driver_instances.values()
            if driver.machine_type == machine_type
        ]

    def _calculate_registry_hash(self):
        """Calculate a hash of the machine registry state."""
        from hashlib import md5

        from plugin import registry as plugin_registry

        data = md5()

        # If the plugin registry has changed, the machine registry hash will change
        plugin_registry.update_plugin_hash()
        data.update(plugin_registry.registry_hash.encode())

        for pk, machine in self.machines.items():
            data.update(str(pk).encode())
            try:
                data.update(str(machine.machine_config.active).encode())
            except:
                # machine does not exist anymore, hash will be different
                pass

        return str(data.hexdigest())

    def _check_reload(self):
        """Check if the registry needs to be reloaded, and reload it."""
        if not self._hash:
            self._hash = self._calculate_registry_hash()

        try:
            reg_hash = get_global_setting('_MACHINE_REGISTRY_HASH', '', create=False)
        except Exception as exc:
            logger.exception('Failed to get machine registry hash: %s', str(exc))
            return False

        if reg_hash and reg_hash != self._hash:
            logger.info('Machine registry has changed - reloading machines')
            self.reload_machines()
            return True

        return False

    def _update_registry_hash(self):
        """Save the current registry hash."""
        self._hash = self._calculate_registry_hash()

        try:
            old_hash = get_global_setting('_MACHINE_REGISTRY_HASH')
        except Exception:
            old_hash = None

        if old_hash != self._hash:
            try:
                logger.info('Updating machine registry hash: %s', str(self._hash))
                set_global_setting('_MACHINE_REGISTRY_HASH', self._hash)
            except (IntegrityError, OperationalError, ProgrammingError):
                pass
            except Exception as exc:
                logger.exception('Failed to update machine registry hash: %s', str(exc))

    def call_machine_function(
        self, machine_id: str, function_name: str, *args, **kwargs
    ):
        """Call a named function against a machine instance.

        Arguments:
            machine_id: The UUID of the machine to call the function against
            function_name: The name of the function to call
        """
        logger.info('call_machine_function: %s -> %s', machine_id, function_name)

        raise_error = kwargs.pop('raise_error', True)

        self._check_reload()

        # Fetch the machine instance based on the provided UUID
        machine = self.get_machine(machine_id)

        if not machine:
            if raise_error:
                raise AttributeError(f"Machine '{machine_id}' not found")
            return

        # Fetch the driver instance based on the machine driver
        driver = machine.driver

        if not driver:
            if raise_error:
                raise AttributeError(f"Machine '{machine_id}' has no specified driver")
            return

        # The function must be registered against the driver
        func = getattr(driver, function_name)

        if not func or not callable(func):
            if raise_error:
                raise AttributeError(
                    f"Driver '{driver.SLUG}' has no callable method '{function_name}'"
                )
            return

        return func(machine, *args, **kwargs)


registry: MachineRegistry = MachineRegistry()


def call_machine_function(machine_id: str, function: str, *args, **kwargs):
    """Global helper function to call a specific function on a machine instance."""
    return registry.call_machine_function(machine_id, function, *args, **kwargs)
