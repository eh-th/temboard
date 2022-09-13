import logging
try:
    from inspect import signature
except ImportError:
    from inspect import getargspec
from textwrap import dedent

from ..toolkit.app import SubCommand
from ..toolkit.taskmanager import RunTaskMixin
from ..model import check_schema
from .app import app


logger = logging.getLogger(__name__)


@app.command
class Schedule(RunTaskMixin, SubCommand):
    """ Schedule a background task. """

    def define_arguments(self, parser):
        parser.description = dedent("""\
        Schedule a task background.

        You need a running temBoard UI to execute this command.
        """)

        parser.add_argument(
            'worker_name',
            metavar='WORKER',
            help=(
                "Global name of the worker function name to execute."
                " Use ? to list available workers."),
        )

        parser.add_argument(
            'worker_args', nargs='*',
            metavar='ARG',
            default=[],
            help="Worker arguments as Python literals.",
        )

    def main(self, args):
        workers = self.iter_workers()

        if '?' == args.worker_name:
            self.print_workers(workers)
        else:
            worker, worker_args = self.compute_worker_args(workers, args)
            check_schema()
            out = worker.defer(
                self.app,
                **build_kwargs_from_args(worker, worker_args)
            )
            logger.info(
                "Worker %s scheduled with task ID %s.",
                args.worker_name, out.content['id'])

        return 0


def build_kwargs_from_args(callable_, args):
    try:
        sig = signature(callable_).parameters
    except NameError:
        sig = getargspec(callable_).args
    names = list(sig.keys())
    names.pop(0)  # Drop app arg
    return dict(zip(names, args))
