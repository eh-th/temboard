import os
import json
import logging
import re
import socket
from getpass import getpass
from textwrap import dedent
from sys import stdout
from urllib.error import HTTPError

from ..errors import UserError
from ..httpsclient import https_request
from ..toolkit.app import SubCommand
from ..tools import validate_parameters
from ..types import T_PASSWORD, T_USERNAME
from .app import app


try:
    input = raw_input
except NameError:
    pass

logger = logging.getLogger(__name__)


@app.command
class Register(SubCommand):
    """Register a PostgreSQL instance to a temBoard UI."""

    def define_arguments(self, parser):
        parser.description = dedent("""\

        This command is interactive. register will ask you username and
        password to call temBoard UI API.

        """)

        parser.add_argument(
            '--host',
            dest='host',
            help="Agent address accessible from UI. Default: %(default)s",
            default=socket.getfqdn(),
        )
        self.app.config_specs['temboard_port'].add_argument(
            parser, '-p', '--port',
            help="Agent listening TCP port. Default: %(default)s",
        )
        parser.add_argument(
            '-g', '--groups',
            dest='groups',
            help="Instance groups list, comma separated. Default: %(default)s",
            default=None,
        )
        parser.add_argument(
            'ui_address',
            metavar='TEMBOARD-UI-ADDRESS',
            help="temBoard UI address to register to.",
        )
        super(Register, self).define_arguments(parser)

    def main(self, args):
        agent_baseurl = "https://{}:{}".format(
            args.host, self.app.config.temboard.port)
        discover_url = agent_baseurl + '/discover'

        try:
            # Getting system/instance informations using agent's discovering
            # API.
            logger.info(
                "Discovering system and PostgreSQL (%s) ...", discover_url)
            code, content, cookies = https_request(
                None,
                'GET',
                discover_url,
                headers={
                    "Content-type": "application/json",
                    "X-Temboard-Agent-Key": app.config.temboard['key'],
                },
            )
            infos = json.loads(content.decode("utf-8"))

            logger.info("Agent responded at %s:%s.", agent_baseurl)
            logger.info(
                "For %s instance at %s listening on port %s.",
                infos['pg_version_summary'],
                infos['pg_data'], infos['pg_port'],
            )

            logger.info("Login at %s ...", args.ui_address)
            username = ask_username()
            password = ask_password()
            code, content, cookies = https_request(
                None,
                'POST',
                "%s/json/login" % (args.ui_address.rstrip('/')),
                headers={
                    "Content-type": "application/json"
                },
                data={'username': username, 'password': password}
            )
            temboard_cookie = None
            for cookie in cookies.split("\n"):
                cookie_content = cookie.split(";")[0]
                if re.match(r'^temboard=.*$', cookie_content):
                    temboard_cookie = cookie_content
                    continue

            if args.groups:
                groups = [g for g in args.groups.split(',')]
            else:
                groups = None

            # POSTing new instance
            logger.info(
                "Registering instance/agent to %s ...", args.ui_address)
            code, content, cookies = https_request(
                None,
                'POST',
                "%s/json/register/instance" % (args.ui_address.rstrip('/')),
                headers={
                    "Content-type": "application/json",
                    "Cookie": temboard_cookie
                },
                data={
                    'hostname': infos['hostname'],
                    'agent_key': app.config.temboard['key'],
                    'agent_address': args.host,
                    'agent_port': str(app.config.temboard['port']),
                    'cpu': infos['cpu'],
                    'memory_size': infos['memory_size'],
                    'pg_port': infos['pg_port'],
                    'pg_data': infos['pg_data'],
                    'pg_version': infos['pg_version'],
                    'pg_version_summary': infos['pg_version_summary'],
                    'plugins': infos['plugins'],
                    'groups': groups
                }
            )
            if code != 200:
                raise HTTPError(code, content)
            logger.info("Done.")
        except UserError:
            raise
        except HTTPError as e:
            msg = json.loads(e.read())['error']
            if e.url.startswith(agent_baseurl):
                fmt = "Failed to contact agent: %s. Are you mixing agents ?"
            raise UserError(fmt % msg)
        except Exception as e:
            raise UserError(str(e) or repr(e))

        return 0


def ask_password():
    try:
        raw_pass = os.environ['TEMBOARD_UI_PASSWORD']
    except KeyError:
        raw_pass = getpass(" Password: ")

    try:
        password = raw_pass
        validate_parameters({'password': password},
                            [('password', T_PASSWORD, False)])
    except HTTPError:
        stdout.write("Invalid password.\n")
        return ask_password()
    return password


def ask_username():
    try:
        raw_username = os.environ['TEMBOARD_UI_USER']
    except KeyError:
        raw_username = input(" Username: ")

    try:
        username = raw_username
        validate_parameters({'username': username},
                            [('username', T_USERNAME, False)])
    except HTTPError:
        stdout.write("Invalid username.\n")
        return ask_username()
    return username
