#!/usr/bin/env python3
"""
LLM Router CLI - Command-line interface for multi-LLM provider routing.

Usage:
    ./scripts/llm-router-cli.py status              # Show provider status
    ./scripts/llm-router-cli.py execute "task"      # Execute a task
    ./scripts/llm-router-cli.py test                # Test all providers
"""

import argparse
import asyncio
import json
import logging
import sys
from pathlib import Path
from typing import Optional

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from src.llm_providers.config_loader import create_router_from_config
from src.llm_providers import TaskComplexity

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


async def show_status(router):
    """Show status of all providers."""
    print("\n=== LLM Router Status ===\n")

    status = router.get_router_status()

    print(f"Router Status: {'Running' if status['running'] else 'Stopped'}")
    print(f"Provider Count: {status['provider_count']}")
    print(f"Last Health Check: {status['last_health_check'] or 'Never'}")
    print(f"Health Check Interval: {status['health_check_interval']}s")
    print(f"Max Retries: {status['max_retries']}")

    print("\n--- Providers ---\n")

    for name, info in status['providers'].items():
        available = info['available']
        status_icon = "✓" if available else "✗"
        status_text = "Available" if available else "Unavailable"

        print(f"{status_icon} {name}")
        print(f"  Status: {status_text}")
        print(f"  Priority: {info['priority']}")
        print(f"  Capabilities: {', '.join(info['capabilities'])}")
        print(f"  Supported Complexity: {', '.join(info['supported_complexity'])}")
        if info['last_check']:
            print(f"  Last Check: {info['last_check']}")
        if info['error']:
            print(f"  Error: {info['error']}")
        print()


async def execute_task(router, prompt: str, complexity: Optional[str] = None):
    """Execute a task with the router."""
    print(f"\n=== Executing Task ===\n")
    print(f"Prompt: {prompt}\n")

    context = {}
    if complexity:
        context['complexity'] = complexity

    response = await router.route_task(prompt, context=context)

    print(f"Provider: {response.provider_name}")
    print(f"Model: {response.model_used}")
    print(f"Success: {response.success}")

    if response.success:
        print(f"Response Time: {response.response_time_ms:.2f}ms")
        if response.tokens_used:
            print(f"Tokens Used: {response.tokens_used}")
        print(f"\nContent:\n{response.content}")
    else:
        print(f"Error: {response.error}")


async def test_providers(router):
    """Test all providers with simple queries."""
    print("\n=== Testing Providers ===\n")

    # Get all providers
    providers = router.registry.list_providers()

    for provider in providers:
        print(f"Testing {provider.name}...")

        # Check availability
        health = await provider.check_availability()
        print(f"  Health Check: {'✓ Available' if health.is_available else '✗ Unavailable'}")

        if health.response_time_ms:
            print(f"  Response Time: {health.response_time_ms:.2f}ms")

        if health.error_message:
            print(f"  Error: {health.error_message}")

        # Try simple task if available
        if health.is_available:
            from src.llm_providers.provider_interface import TaskRequest, ProviderCapability

            request = TaskRequest(
                prompt="Hello, this is a test",
                context={},
                complexity=TaskComplexity.SIMPLE,
                required_capabilities=[ProviderCapability.TEXT_GENERATION],
            )

            try:
                response = await provider.execute_task(request)
                if response.success:
                    print(f"  Test Task: ✓ Success")
                    print(f"  Response: {response.content[:100]}...")
                else:
                    print(f"  Test Task: ✗ Failed - {response.error}")
            except Exception as e:
                print(f"  Test Task: ✗ Exception - {e}")

        print()


async def interactive_mode(router):
    """Interactive mode for testing."""
    print("\n=== Interactive Mode ===")
    print("Enter tasks to execute (or 'quit' to exit)\n")

    while True:
        try:
            prompt = input("Task> ").strip()

            if not prompt:
                continue

            if prompt.lower() in ['quit', 'exit', 'q']:
                break

            if prompt == 'status':
                await show_status(router)
                continue

            await execute_task(router, prompt)
            print()

        except EOFError:
            break
        except KeyboardInterrupt:
            print("\nInterrupted")
            break


async def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="LLM Router CLI - Multi-provider task routing"
    )

    parser.add_argument(
        "command",
        nargs="?",
        choices=["status", "execute", "test", "interactive"],
        help="Command to run",
    )
    parser.add_argument(
        "prompt",
        nargs="?",
        help="Task prompt (for execute command)",
    )
    parser.add_argument(
        "--config",
        type=Path,
        help="Path to configuration file",
    )
    parser.add_argument(
        "--complexity",
        choices=["simple", "moderate", "complex", "critical"],
        help="Override task complexity classification",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Verbose logging",
    )

    args = parser.parse_args()

    # Configure logging
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Create router from config
    try:
        router = create_router_from_config(args.config)
        await router.start()
    except Exception as e:
        print(f"Error initializing router: {e}", file=sys.stderr)
        return 1

    try:
        # Execute command
        if not args.command or args.command == "status":
            await show_status(router)

        elif args.command == "execute":
            if not args.prompt:
                print("Error: prompt required for execute command", file=sys.stderr)
                return 1
            await execute_task(router, args.prompt, args.complexity)

        elif args.command == "test":
            await test_providers(router)

        elif args.command == "interactive":
            await interactive_mode(router)

        return 0

    except Exception as e:
        logger.error(f"Error: {e}", exc_info=True)
        return 1

    finally:
        await router.stop()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
